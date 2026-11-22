#include "sandbox.h"

#include <sddl.h>
#include <shlobj.h>
#include <userenv.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace {
using namespace motif::lx_probe;

constexpr DWORD kJobFlags = JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
                            JOB_OBJECT_LIMIT_PROCESS_MEMORY |
                            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
constexpr SIZE_T kProcessMemory = 64 * 1024 * 1024;
constexpr DWORD kStartupTimeout = 5000;
constexpr DWORD kFixtureTimeout = 5000;

std::wstring SidString(PSID sid) {
  wchar_t* text = nullptr;
  Require(ConvertSidToStringSidW(sid, &text), "encode SID");
  const std::wstring result(text);
  LocalFree(text);
  return result;
}

class Security {
 public:
  explicit Security(const std::wstring& dacl) {
    Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(
                dacl.c_str(), SDDL_REVISION_1, &descriptor_, nullptr),
            "create explicit security descriptor");
    attributes = {sizeof(attributes), descriptor_, FALSE};
  }
  Security(const Security&) = delete;
  Security& operator=(const Security&) = delete;
  ~Security() { LocalFree(descriptor_); }
  SECURITY_ATTRIBUTES attributes{};

 private:
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
};

std::wstring UniqueName() {
  GUID guid{};
  Require(SUCCEEDED(CoCreateGuid(&guid)), "create unique probe identity");
  wchar_t value[40]{};
  Require(StringFromGUID2(guid, value, static_cast<int>(std::size(value))) > 0,
          "format probe identity");
  return L"MotifLxProbe." + std::wstring(value).substr(1, 36);
}

struct Profile {
  std::wstring name;
  PSID sid = nullptr;
  explicit Profile(const std::wstring& unique) : name(unique) {
    const auto status = CreateAppContainerProfile(
        name.c_str(), L"Motif isolation probe", L"Ephemeral test",
        nullptr, 0, &sid);
    if (FAILED(status)) SetLastError(static_cast<DWORD>(status));
    Require(SUCCEEDED(status) && sid, "create zero-capability AppContainer");
  }
  ~Profile() {
    if (sid) FreeSid(sid);
    DeleteAppContainerProfile(name.c_str());
  }
};

struct ProbeFiles {
  std::wstring folder;
  std::wstring worker;
  std::wstring canary;
  bool owns_folder = false;
  bool owns_worker = false;
  bool owns_canary = false;

  ~ProbeFiles() {
    if (owns_canary) DeleteFileW(canary.c_str());
    if (owns_worker) DeleteFileW(worker.c_str());
    if (owns_folder) RemoveDirectoryW(folder.c_str());
  }

  void Prepare(const std::wstring& unique, const std::wstring& user_sid,
               const std::wstring& app_sid) {
    std::array<wchar_t, 32768> temp{};
    const DWORD length = GetTempPathW(static_cast<DWORD>(temp.size()), temp.data());
    Require(length > 0 && length < temp.size(), "resolve temporary directory");
    folder = std::wstring(temp.data(), length) + unique;
    worker = folder + L"\\motif-lx-fixture.exe";
    canary = folder + L"\\private-canary";
    const auto owner_acl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + user_sid + L")";
    Security execute(owner_acl + L"(A;;GRGX;;;" + app_sid + L")");
    Security private_file(owner_acl);
    Require(CreateDirectoryW(folder.c_str(), &execute.attributes),
            "create private probe directory");
    owns_folder = true;

    std::array<wchar_t, 32768> module{};
    const DWORD module_length =
        GetModuleFileNameW(nullptr, module.data(), static_cast<DWORD>(module.size()));
    Require(module_length > 0 && module_length < module.size(),
            "resolve built-in fixture executable");
    const std::wstring controller(module.data(), module_length);
    const auto separator = controller.find_last_of(L"\\/");
    Require(separator != std::wstring::npos, "resolve fixture executable directory");
    const auto worker_source = controller.substr(0, separator + 1) + L"motif_lx_worker.exe";
    const Handle input(CreateFileW(worker_source.c_str(), GENERIC_READ, FILE_SHARE_READ,
                                   nullptr, OPEN_EXISTING, 0, nullptr));
    Require(input.value != INVALID_HANDLE_VALUE, "open fixture executable");
    const Handle output(CreateFileW(worker.c_str(), GENERIC_WRITE, 0,
        &execute.attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    Require(output.value != INVALID_HANDLE_VALUE, "stage readable fixture executable");
    owns_worker = true;
    std::array<char, 32768> buffer{};
    for (;;) {
      DWORD count = 0;
      Require(ReadFile(input.value, buffer.data(),
                       static_cast<DWORD>(buffer.size()), &count, nullptr),
              "read fixture executable");
      if (!count) break;
      DWORD written = 0;
      Require(WriteFile(output.value, buffer.data(), count, &written, nullptr) &&
                  written == count, "write fixture executable");
    }
    const Handle marker(CreateFileW(canary.c_str(), GENERIC_WRITE, 0,
        &private_file.attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    Require(marker.value != INVALID_HANDLE_VALUE, "create host-only canary");
    owns_canary = true;
    DWORD written = 0;
    Require(WriteFile(marker.value, "fixture", 7, &written, nullptr) && written == 7,
            "write host-only canary");
  }
};

class Attributes {
 public:
  Attributes() {
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(nullptr, 4, 0, &size);
    Require(size > 0, "measure launch attributes");
    bytes_.resize(size);
    list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(bytes_.data());
    Require(InitializeProcThreadAttributeList(list, 4, 0, &size),
            "prepare launch attributes");
  }
  ~Attributes() { DeleteProcThreadAttributeList(list); }
  void Set(DWORD_PTR key, void* value, SIZE_T len) {
    Require(UpdateProcThreadAttribute(list, 0, key, value, len, nullptr, nullptr),
            "set launch attribute");
  }
  LPPROC_THREAD_ATTRIBUTE_LIST list = nullptr;

 private:
  std::vector<std::byte> bytes_;
};

u_short BindLoopback(Loopback& listener) {
  listener.socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  Require(listener.socket != INVALID_SOCKET, "open loopback fixture");
  listener.endpoint.sin_family = AF_INET;
  listener.endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int size = sizeof(listener.endpoint);
  Require(bind(listener.socket, reinterpret_cast<const sockaddr*>(&listener.endpoint), size) == 0 &&
              listen(listener.socket, 1) == 0 &&
              getsockname(listener.socket, reinterpret_cast<sockaddr*>(&listener.endpoint), &size) == 0,
          "listen only on a random loopback port");
  return ntohs(listener.endpoint.sin_port);
}

std::wstring WorkerEnvironment() {
  wchar_t* raw = nullptr;
  const HRESULT status =
      SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DONT_VERIFY, nullptr, &raw);
  const std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> local_data(raw, CoTaskMemFree);
  if (FAILED(status)) SetLastError(static_cast<DWORD>(status));
  Require(SUCCEEDED(status) && raw && *raw, "resolve Local AppData for AppContainer");

  std::array<wchar_t, 32768> windows{};
  const UINT length = GetSystemWindowsDirectoryW(
      windows.data(), static_cast<UINT>(windows.size()));
  Require(length > 0 && length < windows.size(), "resolve system Windows directory");

  // Windows needs LOCALAPPDATA to locate the AppContainer profile. Seed only
  // system paths, so the worker does not inherit the runner's environment.
  std::wstring block = L"LOCALAPPDATA=" + std::wstring(local_data.get());
  block.push_back(L'\0');
  block += L"SystemRoot=" + std::wstring(windows.data(), length);
  block.push_back(L'\0');
  block += L"WINDIR=" + std::wstring(windows.data(), length);
  block.push_back(L'\0');
  return block;  // std::wstring adds the final NUL for CreateProcessAsUserW.
}

// The worker inherits only a readiness event and one numeric progress cell.
void Launch(HANDLE token, const ProbeFiles& files, const Profile& profile,
            u_short port, bool stall) {
  const Handle job(CreateJobObjectW(nullptr, nullptr));
  Require(job.value, "create fixture job");
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = kJobFlags;
  limits.BasicLimitInformation.ActiveProcessLimit = 1;
  limits.ProcessMemoryLimit = kProcessMemory;
  JOBOBJECT_BASIC_UI_RESTRICTIONS ui{};
  ui.UIRestrictionsClass = JOB_OBJECT_UILIMIT_ALL;
  Require(SetInformationJobObject(job.value, JobObjectExtendedLimitInformation,
                                  &limits, sizeof(limits)) &&
              SetInformationJobObject(job.value, JobObjectBasicUIRestrictions,
                                      &ui, sizeof(ui)),
          "apply process, memory, and system UI restrictions");

  SECURITY_ATTRIBUTES inheritable{sizeof(inheritable), nullptr, TRUE};
  const Handle ready(CreateEventW(&inheritable, TRUE, FALSE, nullptr));
  Require(ready.value, "create readiness signal");
  const Handle section(CreateFileMappingW(INVALID_HANDLE_VALUE, &inheritable,
                                          PAGE_READWRITE, 0, sizeof(LONG), nullptr));
  Require(section.value, "create fixture progress section");
  const ProgressCell progress(section.value);
  HANDLE allowed_handles[]{ready.value, section.value};
  SECURITY_CAPABILITIES capabilities{profile.sid, nullptr, 0, 0};
  DWORD prohibit_children = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
  DWORD64 mitigation = PROCESS_CREATION_MITIGATION_POLICY_WIN32K_SYSTEM_CALL_DISABLE_ALWAYS_ON;
  Attributes attributes;
  attributes.Set(PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &capabilities,
                 sizeof(capabilities));
  attributes.Set(PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY, &prohibit_children,
                 sizeof(prohibit_children));
  attributes.Set(PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY, &mitigation, sizeof(mitigation));
  attributes.Set(PROC_THREAD_ATTRIBUTE_HANDLE_LIST, allowed_handles, sizeof(allowed_handles));

  std::wstring args = L"motif-lx-fixture " +
      SidString(profile.sid) + L" \"" + files.canary + L"\" " +
      std::to_wstring(port) + L" " +
      std::to_wstring(reinterpret_cast<std::uintptr_t>(ready.value)) +
      (stall ? L" stall " : L" bounded ") +
      std::to_wstring(reinterpret_cast<std::uintptr_t>(section.value));
  auto environment = WorkerEnvironment();
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = attributes.list;
  PROCESS_INFORMATION child{};
  Require(CreateProcessAsUserW(token, files.worker.c_str(), args.data(),
      nullptr, nullptr, TRUE, CREATE_SUSPENDED |
          EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
      environment.data(), files.folder.c_str(), &startup.StartupInfo, &child),
      "create suspended restricted fixture");
  const Handle process(child.hProcess);
  const Handle thread(child.hThread);
  try {
    Require(AssignProcessToJobObject(job.value, process.value), "assign fixture before resume");
    BOOL in_job = FALSE;
    Require(IsProcessInJob(process.value, job.value, &in_job) && in_job,
            "verify fixture job membership");
    VerifyToken(process.value, profile.sid);
    VerifyMitigations(process.value);
    Require(ResumeThread(thread.value) == 1, "start verified fixture");
    const HANDLE events[]{ready.value, process.value};
    const DWORD ready_result = WaitForMultipleObjects(2, events, FALSE, kStartupTimeout);
    if (ready_result != WAIT_OBJECT_0) {
      std::fprintf(stderr, "Worker last completed startup stage %ld\n", progress.Read());
    }
    if (ready_result == WAIT_OBJECT_0 + 1) {
      DWORD code = 0;
      Require(GetExitCodeProcess(process.value, &code), "read worker setup result");
      SetLastError(code);
      Fail("worker exited during its security checks");
    }
    if (ready_result == WAIT_TIMEOUT) SetLastError(ERROR_TIMEOUT);
    Require(ready_result == WAIT_OBJECT_0, "worker did not provide its sandbox evidence");
    if (stall) {
      Require(WaitForSingleObject(process.value, 200) == WAIT_TIMEOUT &&
                  TerminateJobObject(job.value, 0x71) &&
                  WaitForSingleObject(process.value, kFixtureTimeout) == WAIT_OBJECT_0,
              "reap a stalled worker");
    } else {
      Require(WaitForSingleObject(process.value, kFixtureTimeout) == WAIT_OBJECT_0,
              "bounded QuickJS fixtures");
    }
    DWORD code = 0;
    Require(GetExitCodeProcess(process.value, &code), "read fixture result");
    if (code != (stall ? 0x71 : 0)) {
      SetLastError(code);
      Fail("fixture returned unexpected result");
    }
  } catch (...) {
    // Also covers a failure before the process joined its job.
    TerminateProcess(process.value, 0x72);
    WaitForSingleObject(process.value, kFixtureTimeout);
    throw;
  }
}

int Run() {
  const auto unique = UniqueName();
  HANDLE raw = nullptr;
  Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE |
              TOKEN_ASSIGN_PRIMARY, &raw), "open controller token");
  const Handle current(raw);
  const auto token_user = TokenInfo(current.value, TokenUser);
  const auto user_sid = SidString(
      reinterpret_cast<const TOKEN_USER*>(token_user.data())->User.Sid);
  auto removals = PrivilegesToRemove(current.value);
  raw = nullptr;
  Require(CreateRestrictedToken(current.value, 0, 0, nullptr,
              static_cast<DWORD>(removals.size()), removals.data(),
              0, nullptr, &raw), "remove all privileges other than directory traverse");
  const Handle restricted(raw);

  const Profile profile(unique);
  ProbeFiles files;
  files.Prepare(unique, user_sid, SidString(profile.sid));
  const Winsock winsock;
  Loopback server;
  const auto port = BindLoopback(server);
  Launch(restricted.value, files, profile, port, false);
  Launch(restricted.value, files, profile, port, true);
  Launch(restricted.value, files, profile, port, false);
  std::puts("PASS Windows token, Win32k lockdown, child process, canary, TCP, QuickJS, timeout and restart");
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t**) {
  try {
    if (argc == 1) return Run();
    return 81;
  } catch (const std::exception&) {
    return 82;
  }
}

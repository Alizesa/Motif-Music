#include <winsock2.h>
#include <windows.h>
#include <sddl.h>
#include <userenv.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <stdexcept>
#include <string>
#include <vector>

#include "runtime_fixture.h"

namespace {

constexpr DWORD kJobFlags = JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
                            JOB_OBJECT_LIMIT_PROCESS_MEMORY |
                            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
constexpr SIZE_T kProcessMemory = 64 * 1024 * 1024;
constexpr DWORD kStartupTimeout = 5000;
constexpr DWORD kFixtureTimeout = 5000;
int worker_error = 82;

struct Handle {
  HANDLE value;
  explicit Handle(HANDLE handle = nullptr) : value(handle) {}
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  ~Handle() {
    if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
  }
};

[[noreturn]] void Fail(const char* step) {
  const DWORD error = GetLastError();
  std::fprintf(stderr, "%s (Windows status %lu)\n", step,
               static_cast<unsigned long>(error));
  throw std::runtime_error(step);
}

void Require(bool condition, const char* step) {
  if (!condition) Fail(step);
}

std::vector<std::byte> TokenInfo(HANDLE token, TOKEN_INFORMATION_CLASS type) {
  DWORD size = 0;
  GetTokenInformation(token, type, nullptr, 0, &size);
  Require(size > 0 && size <= 65536, "token information size");
  std::vector<std::byte> bytes(size);
  Require(GetTokenInformation(token, type, bytes.data(), size, &size),
          "read actual token");
  return bytes;
}

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
    const Handle input(CreateFileW(module.data(), GENERIC_READ, FILE_SHARE_READ,
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

struct PrivateDesktop {
  HWINSTA station = nullptr;
  HDESK desktop = nullptr;
  ~PrivateDesktop() {
    if (desktop) CloseDesktop(desktop);
    if (station) CloseWindowStation(station);
  }

  void Open(const std::wstring& unique, const std::wstring& user_sid,
            const std::wstring& app_sid) {
    const auto owner = L"D:P(A;;GA;;;SY)(A;;GA;;;" + user_sid + L")";
    Security station_acl(owner + L"(A;;0x0002;;;" + app_sid + L")");
    Security desktop_acl(owner + L"(A;;0x0001;;;" + app_sid + L")");
    const auto original = GetProcessWindowStation();
    station = CreateWindowStationW(unique.c_str(), 0, WINSTA_ALL_ACCESS,
                                  &station_acl.attributes);
    Require(original && station, "create noninteractive window station");
    Require(SetProcessWindowStation(station), "prepare private desktop");
    desktop = CreateDesktopW(L"Probe", nullptr, nullptr, 0,
                             DESKTOP_CREATEWINDOW | DESKTOP_READOBJECTS |
                                 DESKTOP_WRITEOBJECTS,
                             &desktop_acl.attributes);
    Require(SetProcessWindowStation(original), "restore controller window station");
    Require(desktop, "create private desktop");
  }
};

class Attributes {
 public:
  Attributes() {
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(nullptr, 3, 0, &size);
    Require(size > 0, "measure launch attributes");
    bytes_.resize(size);
    list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(bytes_.data());
    Require(InitializeProcThreadAttributeList(list, 3, 0, &size),
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

bool SamePrivilege(LUID a, LUID b) {
  return a.LowPart == b.LowPart && a.HighPart == b.HighPart;
}

LUID TraversePrivilege() {
  LUID traverse{};
  Require(LookupPrivilegeValueW(nullptr, SE_CHANGE_NOTIFY_NAME, &traverse),
          "look up directory traverse privilege");
  return traverse;
}

std::vector<LUID_AND_ATTRIBUTES> PrivilegesToRemove(HANDLE token) {
  const auto raw = TokenInfo(token, TokenPrivileges);
  const auto* privileges = reinterpret_cast<const TOKEN_PRIVILEGES*>(raw.data());
  const auto traverse = TraversePrivilege();
  std::vector<LUID_AND_ATTRIBUTES> result;
  for (DWORD i = 0; i < privileges->PrivilegeCount; ++i) {
    const auto entry = privileges->Privileges[i];
    if (!SamePrivilege(entry.Luid, traverse)) result.push_back(entry);
  }
  return result;
}

void VerifyToken(HANDLE process, PSID expected_sid) {
  HANDLE raw = nullptr;
  Require(OpenProcessToken(process, TOKEN_QUERY, &raw), "open fixture token");
  const Handle token(raw);
  const auto container = TokenInfo(token.value, TokenIsAppContainer);
  const auto sid = TokenInfo(token.value, TokenAppContainerSid);
  const auto caps = TokenInfo(token.value, TokenCapabilities);
  const auto container_sid =
      reinterpret_cast<const TOKEN_APPCONTAINER_INFORMATION*>(sid.data())->TokenAppContainer;
  Require(*reinterpret_cast<const DWORD*>(container.data()) == 1 &&
              container_sid && EqualSid(container_sid, expected_sid) &&
              reinterpret_cast<const TOKEN_GROUPS*>(caps.data())->GroupCount == 0 &&
              PrivilegesToRemove(token.value).empty(),
          "actual fixture token must have no capabilities or system privileges");
}

void VerifyWorkerDesktop(const wchar_t* expected_station) {
  const auto station = GetProcessWindowStation();
  std::array<wchar_t, 120> name{};
  DWORD bytes = 0;
  USEROBJECTFLAGS flags{};
  Require(station &&
              GetUserObjectInformationW(station, UOI_NAME, name.data(), sizeof(name), &bytes) &&
              std::wstring(name.data()) == expected_station &&
              GetUserObjectInformationW(station, UOI_FLAGS, &flags, sizeof(flags), &bytes) &&
              (flags.dwFlags & WSF_VISIBLE) == 0,
          "worker must be outside the interactive window station");
  name.fill(0);
  Require(GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME,
                                  name.data(), sizeof(name), &bytes) &&
              std::wstring(name.data()) == L"Probe",
          "worker must use its private desktop");
}

struct Winsock {
  Winsock() {
    WSADATA info{};
    Require(WSAStartup(MAKEWORD(2, 2), &info) == 0, "initialize fixture sockets");
  }
  ~Winsock() { WSACleanup(); }
};

struct Loopback {
  SOCKET socket = INVALID_SOCKET;
  sockaddr_in endpoint{};
  ~Loopback() {
    if (socket != INVALID_SOCKET) closesocket(socket);
  }
  void Bind() {
    socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    Require(socket != INVALID_SOCKET, "open loopback fixture");
    endpoint.sin_family = AF_INET;
    endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int size = sizeof(endpoint);
    Require(bind(socket, reinterpret_cast<const sockaddr*>(&endpoint), size) == 0 &&
                listen(socket, 1) == 0 &&
                getsockname(socket, reinterpret_cast<sockaddr*>(&endpoint), &size) == 0,
            "listen only on a random loopback port");
  }
};

int Worker(wchar_t** argv) {
  worker_error = 83;
  PSID expected = nullptr;
  Require(ConvertStringSidToSidW(argv[3], &expected), "decode app container identity");
  try {
    VerifyToken(GetCurrentProcess(), expected);
  } catch (...) {
    LocalFree(expected);
    throw;
  }
  LocalFree(expected);
  worker_error = 84;
  VerifyWorkerDesktop(argv[2]);
  BOOL in_job = FALSE;
  PROCESS_MITIGATION_CHILD_PROCESS_POLICY child_policy{};
  Require(IsProcessInJob(GetCurrentProcess(), nullptr, &in_job) && in_job &&
              GetProcessMitigationPolicy(GetCurrentProcess(), ProcessChildProcessPolicy,
                                         &child_policy, sizeof(child_policy)) &&
              child_policy.NoChildProcessCreation,
          "worker must have child process creation disabled");

  worker_error = 85;
  const Handle canary(CreateFileW(argv[4], GENERIC_READ, FILE_SHARE_READ,
                                nullptr, OPEN_EXISTING, 0, nullptr));
  Require(canary.value == INVALID_HANDLE_VALUE && GetLastError() == ERROR_ACCESS_DENIED,
          "worker could not prove a denial reading the host-only canary");
  worker_error = 86;
  const auto port = std::wcstoul(argv[5], nullptr, 10);
  Require(port > 0 && port <= 65535, "invalid fixture port");
  const Winsock winsock;
  Loopback client;
  client.socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (client.socket != INVALID_SOCKET) {
    client.endpoint.sin_family = AF_INET;
    client.endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    client.endpoint.sin_port = htons(static_cast<u_short>(port));
    Require(connect(client.socket, reinterpret_cast<const sockaddr*>(&client.endpoint),
                    sizeof(client.endpoint)) == SOCKET_ERROR &&
                WSAGetLastError() == WSAEACCES,
            "worker could not prove a denial connecting to loopback");
  } else {
    Require(WSAGetLastError() == WSAEACCES, "socket unavailable for an unknown reason");
  }

  const auto signal = reinterpret_cast<HANDLE>(
      static_cast<std::uintptr_t>(std::wcstoull(argv[6], nullptr, 10)));
  Require(SetEvent(signal), "report sandbox readiness");
  if (std::wstring(argv[7]) == L"stall") {
    Sleep(INFINITE);
    return 80;
  }
  return static_cast<int>(motif::lx_probe::RunRuntimeFixtures());
}

// Only the readiness signal is inherited. Fixtures report via the process exit
// code, so the controller has no command or network IPC surface.
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
  Require(ready.value, "create the sole inherited readiness signal");
  HANDLE allowed_handle = ready.value;
  SECURITY_CAPABILITIES capabilities{profile.sid, nullptr, 0, 0};
  DWORD prohibit_children = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
  Attributes attributes;
  attributes.Set(PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &capabilities,
                 sizeof(capabilities));
  attributes.Set(PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY, &prohibit_children,
                 sizeof(prohibit_children));
  attributes.Set(PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &allowed_handle, sizeof(allowed_handle));

  std::wstring desktop = profile.name + L"\\Probe";
  std::wstring args = L"motif-lx-fixture --worker " + profile.name + L" " +
      SidString(profile.sid) + L" \"" + files.canary + L"\" " +
      std::to_wstring(port) + L" " +
      std::to_wstring(reinterpret_cast<std::uintptr_t>(ready.value)) +
      (stall ? L" stall" : L" bounded");
  wchar_t empty_environment[2]{};
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.lpDesktop = desktop.data();
  startup.lpAttributeList = attributes.list;
  PROCESS_INFORMATION child{};
  Require(CreateProcessAsUserW(token, files.worker.c_str(), args.data(),
      nullptr, nullptr, TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW |
          EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
      empty_environment, files.folder.c_str(), &startup.StartupInfo, &child),
      "create suspended restricted fixture");
  const Handle process(child.hProcess);
  const Handle thread(child.hThread);
  try {
    Require(AssignProcessToJobObject(job.value, process.value), "assign fixture before resume");
    BOOL in_job = FALSE;
    Require(IsProcessInJob(process.value, job.value, &in_job) && in_job,
            "verify fixture job membership");
    VerifyToken(process.value, profile.sid);
    Require(ResumeThread(thread.value) == 1, "start verified fixture");
    const HANDLE events[]{ready.value, process.value};
    const DWORD ready_result = WaitForMultipleObjects(2, events, FALSE, kStartupTimeout);
    if (ready_result == WAIT_OBJECT_0 + 1) {
      DWORD code = 0;
      Require(GetExitCodeProcess(process.value, &code), "read worker setup result");
      SetLastError(code);
      Fail("worker exited during its security checks");
    }
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
  PrivateDesktop desktop;
  desktop.Open(unique, user_sid, SidString(profile.sid));
  const Winsock winsock;
  Loopback server;
  server.Bind();
  const auto port = ntohs(server.endpoint.sin_port);
  Launch(restricted.value, files, profile, port, false);
  Launch(restricted.value, files, profile, port, true);
  Launch(restricted.value, files, profile, port, false);
  std::puts("PASS Windows token, desktop, child process, canary, TCP, QuickJS, timeout and restart");
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  try {
    if (argc == 8 && std::wstring(argv[1]) == L"--worker") return Worker(argv);
    if (argc == 1) return Run();
    return 81;
  } catch (const std::exception&) {
    return worker_error;
  }
}

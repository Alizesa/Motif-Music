#include "sandbox.h"

#include <sddl.h>

#include <cstdint>
#include <cwchar>
#include <memory>
#include <string_view>

#include "runtime_fixture.h"
#include "script_runtime.h"

namespace {
using namespace motif::lx_probe;

int worker_error = 82;

void VerifyLoopbackDenial(u_short port, const ProgressCell& progress) {
  const Winsock winsock;
  Loopback client;
  client.socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (client.socket == INVALID_SOCKET) {
    const int error = WSAGetLastError();
    progress.RecordNetworkError(error);
    Require(error == WSAEACCES, "socket unavailable for an unknown reason");
    return;
  }
  u_long nonblocking = 1;
  Require(ioctlsocket(client.socket, FIONBIO, &nonblocking) == 0, "bound loopback connect");
  client.endpoint.sin_family = AF_INET;
  client.endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  client.endpoint.sin_port = htons(port);
  Require(connect(client.socket, reinterpret_cast<const sockaddr*>(&client.endpoint),
                  sizeof(client.endpoint)) == SOCKET_ERROR,
          "isolated worker reached the control listener");
  int error = WSAGetLastError();
  progress.RecordNetworkError(error);
  if (error == WSAEWOULDBLOCK) {
    fd_set writable{};
    fd_set errors{};
    FD_SET(client.socket, &writable);
    FD_SET(client.socket, &errors);
    timeval budget{1, 0};
    const int result = select(0, nullptr, &writable, &errors, &budget);
    if (result == 0) {
      // The controller also verifies the exemption list and checks that its
      // healthy listener received no connection throughout this launch.
      progress.RecordNetworkError(WSAETIMEDOUT);
      return;
    }
    Require(result > 0, "loopback denial did not complete");
    int size = sizeof(error);
    Require(getsockopt(client.socket, SOL_SOCKET, SO_ERROR,
                       reinterpret_cast<char*>(&error), &size) == 0,
            "read loopback connection result");
  }
  progress.RecordNetworkError(error);
  SetLastError(static_cast<DWORD>(error));
  Require(error == WSAEACCES, "worker could not prove a denial connecting to loopback");
}

HANDLE ParseHandle(const wchar_t* text) {
  wchar_t* end = nullptr;
  const auto number = std::wcstoull(text, &end, 10);
  Require(number && end && !*end &&
              number == static_cast<std::uintptr_t>(number),
          "invalid inherited handle");
  return reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(number));
}

int ReadCatalog(void* opaque, int command) {
  const auto& progress = *static_cast<ProgressCell*>(opaque);
  progress.RequestCatalog(command);
  const auto deadline = GetTickCount64() + 1000;
  do {
    const LONG result = progress.CatalogReply();
    if (result != 0) return result;
    Sleep(2);
  } while (GetTickCount64() < deadline);
  return -1;
}

bool ReadExact(HANDLE pipe, void* destination, DWORD size) {
  auto* cursor = static_cast<char*>(destination);
  while (size) {
    DWORD received = 0;
    if (!ReadFile(pipe, cursor, size, &received, nullptr) || !received) return false;
    cursor += received;
    size -= received;
  }
  return true;
}

std::string ReadFrame(HANDLE pipe, size_t maximum) {
  DWORD size = 0;
  if (!ReadExact(pipe, &size, sizeof(size)) || !size || size > maximum) return {};
  std::string data(size, '\0');
  return ReadExact(pipe, data.data(), size) ? data : std::string();
}

std::string ReadScript(HANDLE pipe) {
  DWORD total = 0;
  if (!ReadExact(pipe, &total, sizeof(total)) || !total || total > kLxScriptBytes) return {};
  std::string script;
  script.reserve(total);
  while (script.size() < total) {
    const auto remaining = total - script.size();
    const auto part = ReadFrame(pipe, remaining < 32768 ? remaining : 32768);
    if (part.empty()) return {};
    script += part;
  }
  return script;
}

bool WriteExact(HANDLE pipe, const void* data, DWORD size) {
  const auto* cursor = static_cast<const char*>(data);
  while (size) {
    DWORD sent = 0;
    if (!WriteFile(pipe, cursor, size, &sent, nullptr) || !sent) return false;
    cursor += sent;
    size -= sent;
  }
  return true;
}

bool WriteFrame(HANDLE pipe, char type, std::string_view data) {
  if (data.empty() || data.size() > kLxMessageBytes) return false;
  const auto length = static_cast<DWORD>(data.size() + 1);
  return WriteExact(pipe, &length, sizeof(length)) && WriteExact(pipe, &type, 1) &&
         WriteExact(pipe, data.data(), static_cast<DWORD>(data.size()));
}

struct AppPipes {
  HANDLE input;
  HANDLE output;
};

std::string RelayScriptRequest(void* opaque, std::string_view message) {
  const auto pipes = *static_cast<const AppPipes*>(opaque);
  if (!WriteFrame(pipes.output, 'Q', message)) return {};
  return ReadFrame(pipes.input, kLxMessageBytes);
}

int Worker(int argc, wchar_t** argv) {
  ProgressCell progress(ParseHandle(argv[6]));
  progress.Mark(1);
  worker_error = 83;
  PSID raw = nullptr;
  Require(ConvertStringSidToSidW(argv[1], &raw), "decode AppContainer identity");
  const std::unique_ptr<void, decltype(&LocalFree)> sid(raw, LocalFree);
  VerifyToken(GetCurrentProcess(), sid.get());
  progress.Mark(2);

  worker_error = 84;
  BOOL in_job = FALSE;
  Require(IsProcessInJob(GetCurrentProcess(), nullptr, &in_job) && in_job,
          "worker must run inside a job");
  VerifyMitigations(GetCurrentProcess());
  progress.Mark(3);

  worker_error = 85;
  const Handle canary(CreateFileW(argv[2], GENERIC_READ, FILE_SHARE_READ,
                                nullptr, OPEN_EXISTING, 0, nullptr));
  Require(canary.value == INVALID_HANDLE_VALUE && GetLastError() == ERROR_ACCESS_DENIED,
          "worker could not prove a denial reading the host-only canary");
  progress.Mark(4);

  worker_error = 86;
  const auto port = std::wcstoul(argv[3], nullptr, 10);
  Require(port > 0 && port <= 65535, "invalid fixture port");
  VerifyLoopbackDenial(static_cast<u_short>(port), progress);
  progress.Mark(5);
  const std::wstring_view mode(argv[5]);
  Require(mode == L"stall" || mode == L"bounded" ||
              mode == L"lx-fixed" || mode == L"lx-timeout" ||
              mode == L"lx-script", "invalid fixture mode");
  Require(argc == (mode == L"lx-script" ? 9 : 7), "invalid worker arguments");
  Require(SetEvent(ParseHandle(argv[4])), "report sandbox readiness");
  if (mode == L"lx-script") {
    const Handle input(ParseHandle(argv[7]));
    const Handle output(ParseHandle(argv[8]));
    if (GetFileType(input.value) != FILE_TYPE_PIPE ||
        GetFileType(output.value) != FILE_TYPE_PIPE) return 91;
    AppPipes pipes{input.value, output.value};
    const auto parameters = ReadFrame(input.value, kLxMessageBytes);
    const auto script = ReadScript(input.value);
    if (parameters.empty() || script.empty()) return 91;
    const auto result = RunLxScript(script, parameters, RelayScriptRequest, &pipes);
    return WriteFrame(output.value, 'D', result) ? 0 : 91;
  }
  if (mode == L"stall") {
    Sleep(INFINITE);
    return 80;
  }
  if (mode == L"lx-fixed" || mode == L"lx-timeout") {
    return RunPlaybackFixture(mode == L"lx-timeout", ReadCatalog, &progress);
  }
  return static_cast<int>(RunRuntimeFixtures());
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 7 && argc != 9) return 81;
  try {
    return Worker(argc, argv);
  } catch (const std::exception&) {
    return worker_error;
  }
}

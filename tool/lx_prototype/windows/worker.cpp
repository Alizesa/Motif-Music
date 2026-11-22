#include "sandbox.h"

#include <sddl.h>

#include <cstdint>
#include <cwchar>
#include <memory>
#include <string_view>

#include "runtime_fixture.h"

namespace {
using namespace motif::lx_probe;

int worker_error = 82;

void VerifyLoopbackDenial(u_short port) {
  const Winsock winsock;
  Loopback client;
  client.socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (client.socket == INVALID_SOCKET) {
    Require(WSAGetLastError() == WSAEACCES, "socket unavailable for an unknown reason");
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
  if (error == WSAEWOULDBLOCK) {
    fd_set writable{};
    fd_set errors{};
    FD_SET(client.socket, &writable);
    FD_SET(client.socket, &errors);
    timeval budget{1, 0};
    const int result = select(0, nullptr, &writable, &errors, &budget);
    if (result == 0) SetLastError(ERROR_TIMEOUT);
    Require(result > 0, "loopback denial did not complete");
    int size = sizeof(error);
    Require(getsockopt(client.socket, SOL_SOCKET, SO_ERROR,
                       reinterpret_cast<char*>(&error), &size) == 0,
            "read loopback connection result");
  }
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

int Worker(wchar_t** argv) {
  const ProgressCell progress(ParseHandle(argv[6]));
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
  VerifyLoopbackDenial(static_cast<u_short>(port));
  progress.Mark(5);
  const std::wstring_view mode(argv[5]);
  Require(mode == L"stall" || mode == L"bounded", "invalid fixture mode");
  Require(SetEvent(ParseHandle(argv[4])), "report sandbox readiness");
  if (mode == L"stall") {
    Sleep(INFINITE);
    return 80;
  }
  return static_cast<int>(RunRuntimeFixtures());
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 7) return 81;
  try {
    return Worker(argv);
  } catch (const std::exception&) {
    return worker_error;
  }
}

#pragma once

#include <winsock2.h>
#include <windows.h>

#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

namespace motif::lx_probe {

struct Handle {
  HANDLE value;
  explicit Handle(HANDLE handle = nullptr) : value(handle) {}
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  ~Handle() {
    if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
  }
};

[[noreturn]] inline void Fail(const char* step) {
  const DWORD error = GetLastError();
  std::fprintf(stderr, "%s (Windows status %lu)\n", step,
               static_cast<unsigned long>(error));
  throw std::runtime_error(step);
}

inline void Require(bool condition, const char* step) {
  if (!condition) Fail(step);
}

inline std::vector<std::byte> TokenInfo(HANDLE token, TOKEN_INFORMATION_CLASS type) {
  DWORD size = 0;
  GetTokenInformation(token, type, nullptr, 0, &size);
  Require(size > 0 && size <= 65536, "token information size");
  std::vector<std::byte> bytes(size);
  Require(GetTokenInformation(token, type, bytes.data(), size, &size),
          "read actual token");
  return bytes;
}

inline std::vector<LUID_AND_ATTRIBUTES> PrivilegesToRemove(HANDLE token) {
  const auto raw = TokenInfo(token, TokenPrivileges);
  const auto* privileges = reinterpret_cast<const TOKEN_PRIVILEGES*>(raw.data());
  LUID traverse{};
  Require(LookupPrivilegeValueW(nullptr, SE_CHANGE_NOTIFY_NAME, &traverse),
          "look up directory traverse privilege");
  std::vector<LUID_AND_ATTRIBUTES> result;
  for (DWORD i = 0; i < privileges->PrivilegeCount; ++i) {
    const auto entry = privileges->Privileges[i];
    if (entry.Luid.LowPart != traverse.LowPart ||
        entry.Luid.HighPart != traverse.HighPart) {
      result.push_back(entry);
    }
  }
  return result;
}

inline void VerifyToken(HANDLE process, PSID expected_sid) {
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

inline void VerifyMitigations(HANDLE process) {
  PROCESS_MITIGATION_SYSTEM_CALL_DISABLE_POLICY win32k{};
  PROCESS_MITIGATION_CHILD_PROCESS_POLICY children{};
  Require(GetProcessMitigationPolicy(process, ProcessSystemCallDisablePolicy,
                                         &win32k, sizeof(win32k)) &&
              win32k.DisallowWin32kSystemCalls &&
              GetProcessMitigationPolicy(process, ProcessChildProcessPolicy,
                                         &children, sizeof(children)) &&
              children.NoChildProcessCreation,
          "worker must be unable to use the desktop or create child processes");
}

struct Winsock {
  Winsock() {
    WSADATA info{};
    const int error = WSAStartup(MAKEWORD(2, 2), &info);
    if (error != 0) SetLastError(static_cast<DWORD>(error));
    Require(error == 0, "initialize fixture sockets");
  }
  ~Winsock() { WSACleanup(); }
};

struct Loopback {
  SOCKET socket = INVALID_SOCKET;
  sockaddr_in endpoint{};
  ~Loopback() {
    if (socket != INVALID_SOCKET) closesocket(socket);
  }
};

struct ProgressCell {
  static constexpr SIZE_T kBytes = 2 * sizeof(LONG);
  volatile LONG* value;
  explicit ProgressCell(HANDLE section) : value(static_cast<volatile LONG*>(
      MapViewOfFile(section, FILE_MAP_WRITE, 0, 0, kBytes))) {
    Require(value, "map fixture progress");
  }
  ~ProgressCell() { UnmapViewOfFile(const_cast<LONG*>(value)); }
  ProgressCell(const ProgressCell&) = delete;
  ProgressCell& operator=(const ProgressCell&) = delete;
  void Mark(LONG stage) const { InterlockedExchange(value, stage); }
  LONG Read() const { return InterlockedCompareExchange(value, 0, 0); }
  void RecordNetworkError(LONG status) const {
    InterlockedExchange(value + 1, status);
  }
  LONG NetworkError() const { return InterlockedCompareExchange(value + 1, 0, 0); }
};

}  // namespace motif::lx_probe

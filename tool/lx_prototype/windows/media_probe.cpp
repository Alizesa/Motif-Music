#include <windows.h>

#include <cstdio>
#include <cstring>
#include <filesystem>

#include "media_fixture.h"

int wmain(int argc, wchar_t** argv) {
  if (argc != 2 || !std::filesystem::path(argv[1]).is_absolute()) return 5;
  const HMODULE library = LoadLibraryExW(argv[1], nullptr,
                                        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                                        LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!library) {
    std::fprintf(stderr, "Could not load bundled mpv fixture (%lu)\n",
                 static_cast<unsigned long>(GetLastError()));
    return 6;
  }
  const auto symbol = [](void* handle, const char* name) {
    const auto address = GetProcAddress(static_cast<HMODULE>(handle), name);
    void* resolved = nullptr;
    static_assert(sizeof(resolved) == sizeof(address));
    std::memcpy(&resolved, &address, sizeof(resolved));
    return resolved;
  };
  const int result = motif::lx_probe::RunMediaFixtures(library, symbol);
  FreeLibrary(library);
  if (result == 0) {
    std::puts("PASS libmpv controlled WAV, seek, playlist rejection and cancellation");
  } else {
    std::fprintf(stderr, "libmpv fixture failed at gate %d\n", result);
  }
  return result;
}

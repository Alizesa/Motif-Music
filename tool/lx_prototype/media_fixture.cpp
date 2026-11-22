#include "media_fixture.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>
#include <string_view>
#include <thread>

#include <mpv/client.h>
#include <mpv/stream_cb.h>

namespace motif::lx_probe {
namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr char kScheme[] = "motif-lx-probe";
constexpr char kWaveUrl[] = "motif-lx-probe://single-wave";
constexpr char kPlaylistUrl[] = "motif-lx-probe://list";
constexpr char kStallUrl[] = "motif-lx-probe://stall";
constexpr std::string_view kPlaylist =
    "#EXTM3U\nmotif-lx-probe://unexpected-reference\n";
constexpr uint32_t kBytesPerSecond = 32000;
constexpr uint32_t kDataSize = kBytesPerSecond * 180;
constexpr int64_t kWaveSize = 44 + kDataSize;
constexpr uint64_t kReadChunk = 32 * 1024;

void PutLittleEndian(char* destination, uint32_t value, size_t bytes) {
  for (size_t i = 0; i < bytes; ++i) {
    destination[i] = static_cast<char>((value >> (i * 8)) & 255);
  }
}

std::array<char, 44> WaveHeader() {
  std::array<char, 44> header{};
  std::memcpy(header.data(), "RIFF", 4);
  PutLittleEndian(header.data() + 4, 36 + kDataSize, 4);
  std::memcpy(header.data() + 8, "WAVEfmt ", 8);
  PutLittleEndian(header.data() + 16, 16, 4);
  PutLittleEndian(header.data() + 20, 1, 2);
  PutLittleEndian(header.data() + 22, 1, 2);
  PutLittleEndian(header.data() + 24, 16000, 4);
  PutLittleEndian(header.data() + 28, kBytesPerSecond, 4);
  PutLittleEndian(header.data() + 32, 2, 2);
  PutLittleEndian(header.data() + 34, 16, 2);
  std::memcpy(header.data() + 36, "data", 4);
  PutLittleEndian(header.data() + 40, kDataSize, 4);
  return header;
}

enum class Stream { wave, list, stall };

struct State {
  const std::array<char, 44> wave_header = WaveHeader();
  std::atomic<int> opens{0};
  std::atomic<int> closes{0};
  std::atomic<int> forbidden_opens{0};
  std::atomic<int64_t> bytes_read{0};
  std::atomic<int64_t> last_seek{0};
  std::atomic<bool> stalled{false};
  std::atomic<bool> cancelled_stall{false};
};

struct Cursor {
  State& state;
  Stream stream;
  int64_t offset = 0;
  std::atomic<bool> cancelled{false};
};

int64_t Size(void* cookie) {
  const auto& cursor = *static_cast<Cursor*>(cookie);
  return cursor.stream == Stream::list ? static_cast<int64_t>(kPlaylist.size())
                                      : kWaveSize;
}

int64_t Read(void* cookie, char* target, uint64_t requested) {
  auto& cursor = *static_cast<Cursor*>(cookie);
  if (cursor.stream == Stream::stall) {
    cursor.state.stalled = true;
    const auto deadline = Clock::now() + 3s;
    while (!cursor.cancelled && Clock::now() < deadline) {
      std::this_thread::sleep_for(2ms);
    }
    return -1;
  }
  if (cursor.cancelled) return -1;
  const auto remaining = static_cast<uint64_t>(Size(cookie) - cursor.offset);
  const auto count = static_cast<size_t>(std::min({requested, remaining, kReadChunk}));
  if (count == 0) return 0;
  if (cursor.stream == Stream::list) {
    std::memcpy(target, kPlaylist.data() + cursor.offset, count);
  } else {
    const auto begin = static_cast<size_t>(cursor.offset);
    const auto& header = cursor.state.wave_header;
    const auto header_count = begin >= header.size() ? 0
        : std::min(count, header.size() - begin);
    if (header_count) std::memcpy(target, header.data() + begin, header_count);
    std::memset(target + header_count, 0, count - header_count);
  }
  cursor.offset += static_cast<int64_t>(count);
  cursor.state.bytes_read += static_cast<int64_t>(count);
  return static_cast<int64_t>(count);
}

int64_t Seek(void* cookie, int64_t offset) {
  auto& cursor = *static_cast<Cursor*>(cookie);
  if (cursor.cancelled || offset < 0 || offset > Size(cookie)) return -1;
  cursor.state.last_seek = offset;
  return cursor.offset = offset;
}

void Cancel(void* cookie) {
  auto& cursor = *static_cast<Cursor*>(cookie);
  cursor.cancelled = true;
  if (cursor.stream == Stream::stall && cursor.state.stalled) {
    cursor.state.cancelled_stall = true;
  }
}

void Close(void* cookie) {
  auto* cursor = static_cast<Cursor*>(cookie);
  ++cursor->state.closes;
  delete cursor;
}

int Open(void* user, char* url, mpv_stream_cb_info* info) {
  auto& state = *static_cast<State*>(user);
  const std::string_view candidate(url);
  Stream stream;
  if (candidate == kWaveUrl) {
    stream = Stream::wave;
  } else if (candidate == kPlaylistUrl) {
    stream = Stream::list;
  } else if (candidate == kStallUrl) {
    stream = Stream::stall;
  } else {
    ++state.forbidden_opens;
    return MPV_ERROR_LOADING_FAILED;
  }
  auto* cursor = new (std::nothrow) Cursor{state, stream};
  if (!cursor) return MPV_ERROR_NOMEM;
  ++state.opens;
  info->cookie = cursor;
  info->read_fn = Read;
  info->seek_fn = Seek;
  info->size_fn = Size;
  info->close_fn = Close;
  info->cancel_fn = Cancel;
  return 0;
}

struct Api {
  decltype(&mpv_client_api_version) version = nullptr;
  decltype(&mpv_create) create = nullptr;
  decltype(&mpv_initialize) initialize = nullptr;
  decltype(&mpv_set_option_string) option = nullptr;
  decltype(&mpv_stream_cb_add_ro) add_stream = nullptr;
  decltype(&mpv_command) command = nullptr;
  decltype(&mpv_wait_event) wait = nullptr;
  decltype(&mpv_terminate_destroy) destroy = nullptr;

  bool Load(void* library, void* (*symbol)(void*, const char*)) {
    const auto resolve = [&](auto& slot, const char* name) {
      const void* address = symbol(library, name);
      static_assert(sizeof(slot) == sizeof(address));
      std::memcpy(&slot, &address, sizeof(slot));
      return slot != nullptr;
    };
    return resolve(version, "mpv_client_api_version") &&
           resolve(create, "mpv_create") && resolve(initialize, "mpv_initialize") &&
           resolve(option, "mpv_set_option_string") &&
           resolve(add_stream, "mpv_stream_cb_add_ro") &&
           resolve(command, "mpv_command") && resolve(wait, "mpv_wait_event") &&
           resolve(destroy, "mpv_terminate_destroy");
  }
};

class Player {
 public:
  explicit Player(const Api& api) : api_(api), handle_(api_.create()) {}
  ~Player() { if (handle_) api_.destroy(handle_); }
  Player(const Player&) = delete;
  Player& operator=(const Player&) = delete;

  bool Init(State& state) {
    if (!handle_) return false;
    const int scripts = api_.option(handle_, "load-scripts", "no");
    // mpv compiles both options out when it has no Lua, JS or C plugins.
    if (scripts < 0 &&
        (scripts != MPV_ERROR_OPTION_NOT_FOUND ||
         api_.option(handle_, "scripts", "") != MPV_ERROR_OPTION_NOT_FOUND)) {
      std::fputs("Could not disable libmpv script loading\n", stderr);
      return false;
    }
    const char* options[][2] = {
        {"config", "no"}, {"terminal", "no"},
        {"access-references", "no"}, {"load-unsafe-playlists", "no"},
        {"autoload-files", "no"}, {"demuxer", "lavf"},
        {"demuxer-lavf-format", "wav"}, {"ao", "null"}, {"vo", "null"},
        {"audio-display", "no"}, {"pause", "yes"}, {"cache", "no"},
        {"demuxer-readahead-secs", "0"},
    };
    for (const auto& pair : options) {
      if (api_.option(handle_, pair[0], pair[1]) < 0) {
        std::fprintf(stderr, "libmpv rejected probe option %s\n", pair[0]);
        return false;
      }
    }
    return api_.initialize(handle_) == 0 &&
           api_.add_stream(handle_, kScheme, &state, Open) == 0;
  }

  bool Load(const char* uri) {
    const char* request[] = {"loadfile", uri, "replace", nullptr};
    return api_.command(handle_, request) >= 0;
  }

  bool SeekFar() {
    const char* request[] = {"seek", "120", "absolute+exact", nullptr};
    return api_.command(handle_, request) >= 0;
  }

  bool Stop() {
    const char* request[] = {"stop", nullptr};
    return api_.command(handle_, request) >= 0;
  }

  template <typename Condition>
  bool WaitFor(Condition ready) {
    const auto deadline = Clock::now() + 5s;
    while (Clock::now() < deadline) {
      if (ready(api_.wait(handle_, 0.025))) return true;
    }
    return false;
  }

 private:
  const Api& api_;
  mpv_handle* const handle_;
};

bool Wave(const Api& api) {
  State state;
  {
    Player player(api);
    if (!player.Init(state) || !player.Load(kWaveUrl) ||
        !player.WaitFor([](mpv_event* event) { return event->event_id == MPV_EVENT_FILE_LOADED; }) ||
        state.opens != 1 || state.bytes_read <= 0) return false;
    state.last_seek = 0;
    if (!player.SeekFar() || !player.WaitFor([&](mpv_event*) {
          return state.last_seek > 60 * kBytesPerSecond;
        })) return false;
  }
  return state.opens == 1 && state.closes == 1 && state.forbidden_opens == 0 &&
         state.bytes_read < kWaveSize;
}

bool PlaylistRejected(const Api& api) {
  State state;
  {
    Player player(api);
    if (!player.Init(state) || !player.Load(kPlaylistUrl) ||
        !player.WaitFor([](mpv_event* event) {
          if (event->event_id != MPV_EVENT_END_FILE || !event->data) return false;
          const auto* end = static_cast<const mpv_event_end_file*>(event->data);
          return end->reason == MPV_END_FILE_REASON_ERROR;
        })) return false;
  }
  return state.opens == 1 && state.bytes_read > 0 &&
         state.closes == 1 && state.forbidden_opens == 0;
}

bool CancelStall(const Api& api) {
  State state;
  {
    Player player(api);
    if (!player.Init(state) || !player.Load(kStallUrl) ||
        !player.WaitFor([&](mpv_event*) { return state.stalled.load(); })) {
      return false;
    }
    const auto start = Clock::now();
    if (!player.Stop() ||
        !player.WaitFor([&](mpv_event*) { return state.closes == 1; }) ||
        Clock::now() - start >= 2s) {
      return false;
    }
  }
  return state.cancelled_stall && state.opens == 1 &&
         state.closes == 1 && state.forbidden_opens == 0;
}

}  // namespace

int RunMediaFixtures(void* library, void* (*symbol)(void*, const char*)) {
  Api api;
  // The version check precedes registration, which passes versioned structs.
  if (!library || !api.Load(library, symbol) ||
      api.version() != MPV_CLIENT_API_VERSION) return 1;
  if (!Wave(api)) return 2;
  if (!PlaylistRejected(api)) return 3;
  if (!CancelStall(api)) return 4;
  return 0;
}

}  // namespace motif::lx_probe

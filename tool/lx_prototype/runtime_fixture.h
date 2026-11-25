#pragma once

namespace motif::lx_probe {

// These fixtures exercise the runtime using built-in JavaScript.
enum class RuntimeResult : int {
  ok = 0,
  setup = 1,
  globals_or_promise = 2,
  memory_limit = 3,
  interrupt = 4,
};

RuntimeResult RunRuntimeFixtures();

// One bounded outbound IPC operation. No script text or arbitrary target is
// supplied to this native fixture.
using FixtureCatalog = int (*)(void*, int);
int RunPlaybackFixture(bool timeout, FixtureCatalog catalog, void* opaque);

}  // namespace motif::lx_probe

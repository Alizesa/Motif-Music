#pragma once

namespace motif::lx_probe {

// The probe has no entry point that accepts external JavaScript.
enum class RuntimeResult : int {
  ok = 0,
  setup = 1,
  globals_or_promise = 2,
  memory_limit = 3,
  interrupt = 4,
};

RuntimeResult RunRuntimeFixtures();

}  // namespace motif::lx_probe

#pragma once

namespace motif::lx_probe {

// This owns no network or filesystem access. The native library is supplied
// by the stand-alone test controller, and all stream data is synthetic.
int RunMediaFixtures(void* library, void* (*symbol)(void*, const char*));

}  // namespace motif::lx_probe

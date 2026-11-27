#pragma once

#include <string>
#include <string_view>

namespace motif::lx_probe {

constexpr size_t kLxScriptBytes = 768 * 1024;
constexpr size_t kLxMessageBytes = 64 * 1024;
constexpr int kLxScriptTimeoutSeconds = 26;
constexpr int kLxScriptExchangeLimit = 2400;
using ScriptRequest = std::string (*)(void*, std::string_view);

// A single initialization and optional musicUrl invocation. The callback sends
// one bounded Q (JSON with id), P (next completion) or X<id> (cancel) to the host.
std::string RunLxScript(std::string_view script, std::string_view parameters,
                        ScriptRequest request, void* opaque);

}  // namespace motif::lx_probe

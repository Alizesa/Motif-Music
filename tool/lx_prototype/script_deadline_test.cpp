#include "script_runtime.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <string_view>

namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

struct Exchange {
  int requests = 0;
  bool pending = false;
  bool invalid = false;
  Clock::time_point due;
};

std::string Reply(void* opaque, std::string_view message) {
  auto& exchange = *static_cast<Exchange*>(opaque);
  if (!exchange.pending && message.starts_with("Q") &&
      message.find("https://api.fixture.invalid/lookup") != std::string_view::npos &&
      ++exchange.requests <= 3) {
    exchange.pending = true;
    exchange.due = Clock::now() + (exchange.requests < 3 ? 3100ms : 10ms);
    return R"({"pending":true})";
  }
  if (exchange.pending && message == "P") {
    if (Clock::now() < exchange.due) return R"({"pending":true})";
    exchange.pending = false;
    return exchange.requests < 3 ? R"({"error":"transport"})"
        : R"({"response":{"statusCode":200,"headers":{},"body":"https://media.fixture.invalid/track.mp3"}})";
  }
  exchange.invalid = true;
  return {};
}
}  // namespace

int main() {
  constexpr std::string_view script = R"JS(
    lx.on(lx.EVENT_NAMES.request, async () => {
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          return await new Promise((resolve, reject) => {
            lx.request('https://api.fixture.invalid/lookup', {}, (error, response, body) => {
              if (error) reject(error); else resolve(body);
            });
          });
        } catch (_) {}
      }
      throw new Error('All fixture candidates failed');
    });
    lx.send(lx.EVENT_NAMES.inited, {sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});
  )JS";
  constexpr std::string_view parameters = R"({"env":"mobile","info":{"name":"fixture"},"event":{"source":"tx","action":"musicUrl","info":{"type":"128k","musicInfo":{"songmid":"fixture"}}}})";
  Exchange exchange;
  const auto begin = Clock::now();
  const auto reply = motif::lx_probe::RunLxScript(script, parameters, Reply, &exchange);
  const auto elapsed = Clock::now() - begin;
  if (exchange.invalid || exchange.requests != 3 || elapsed < 6s || elapsed >= 12s ||
      reply != R"({"url":"https://media.fixture.invalid/track.mp3"})") {
    std::fputs("FAIL delayed script candidate contract\n", stderr);
    return 1;
  }
  std::puts("PASS native script candidate recovery beyond the former six-second limit; zero network");
  return 0;
}

#include "runtime_fixture.h"
#include "script_runtime.h"

#include <chrono>
#include <cstdint>
#include <cstring>
#include <initializer_list>

#include "quickjs.h"

namespace motif::lx_probe {
namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr size_t kHeapLimit = 24 * 1024 * 1024;
constexpr size_t kStackLimit = 512 * 1024;

class Runtime {
 public:
  Runtime() {
    if (!rt_) return;
    JS_SetMemoryLimit(rt_, kHeapLimit);
    JS_SetMaxStackSize(rt_, kStackLimit);
    ctx_ = JS_NewContext(rt_);
    JS_SetInterruptHandler(rt_, Interrupt, this);
  }
  Runtime(const Runtime&) = delete;
  Runtime& operator=(const Runtime&) = delete;
  ~Runtime() {
    if (ctx_) JS_FreeContext(ctx_);
    if (rt_) JS_FreeRuntime(rt_);
  }

  explicit operator bool() const { return ctx_ != nullptr; }
  bool interrupted() const { return interrupted_; }
  JSContext* context() const { return ctx_; }

  void SetBudget(Clock::duration budget) { deadline_ = Clock::now() + budget; }

  JSValue Eval(const char* source) {
    return JS_Eval(ctx_, source, std::strlen(source), "<builtin-lx-fixture>",
                   JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT);
  }

  bool RunJobs() {
    for (int count = 0; count < 16 && Clock::now() < deadline_; ++count) {
      JSContext* job_context = nullptr;
      const int result = JS_ExecutePendingJob(rt_, &job_context);
      if (result == 0) return true;
      if (result < 0) return false;
    }
    return false;
  }

 private:
  static int Interrupt(JSContext*, void* opaque) {
    auto* self = static_cast<Runtime*>(opaque);
    if (Clock::now() < self->deadline_) return 0;
    self->interrupted_ = true;
    return 1;
  }

  JSRuntime* rt_ = JS_NewRuntime();
  JSContext* ctx_ = nullptr;
  Clock::time_point deadline_ = Clock::time_point::max();
  bool interrupted_ = false;
};

RuntimeResult CheckGlobalsAndPromise() {
  Runtime runtime;
  if (!runtime) return RuntimeResult::setup;
  runtime.SetBudget(1s);
  auto* ctx = runtime.context();
  auto value = runtime.Eval(R"JS(
    for (const name of ['process', 'require', 'std', 'os', 'fetch',
                        'XMLHttpRequest', 'WebSocket', 'Worker',
                        'setTimeout', 'document', 'window']) {
      if (name in globalThis) throw new Error('Unexpected host API');
    }
    globalThis.probeAnswer = 0;
    Promise.resolve(42).then(value => { globalThis.probeAnswer = value; });
  )JS");
  const bool evaluated = !JS_IsException(value);
  JS_FreeValue(ctx, value);
  if (!evaluated || !runtime.RunJobs()) {
    return RuntimeResult::globals_or_promise;
  }
  value = runtime.Eval("globalThis.probeAnswer === 42");
  const bool passed = JS_IsBool(value) && JS_ToBool(ctx, value) == 1;
  JS_FreeValue(ctx, value);
  return passed ? RuntimeResult::ok : RuntimeResult::globals_or_promise;
}

RuntimeResult CheckMemory() {
  Runtime runtime;
  if (!runtime) return RuntimeResult::setup;
  runtime.SetBudget(1s);
  auto* ctx = runtime.context();
  auto value = runtime.Eval("new ArrayBuffer(25 * 1024 * 1024)");
  const bool failed = JS_IsException(value) && !runtime.interrupted();
  JS_FreeValue(ctx, value);
  if (!failed) return RuntimeResult::memory_limit;
  auto exception = JS_GetException(ctx);
  const char* description = JS_ToCString(ctx, exception);
  const bool allocation_refused =
      description != nullptr && std::strcmp(description, "InternalError: out of memory") == 0;
  if (description) JS_FreeCString(ctx, description);
  JS_FreeValue(ctx, exception);
  return allocation_refused ? RuntimeResult::ok : RuntimeResult::memory_limit;
}

RuntimeResult CheckInterrupt() {
  Runtime runtime;
  if (!runtime) return RuntimeResult::setup;
  runtime.SetBudget(150ms);
  auto* ctx = runtime.context();
  auto value = runtime.Eval("for (;;) {}");
  const bool interrupted = JS_IsException(value) && runtime.interrupted();
  JS_FreeValue(ctx, value);
  return interrupted ? RuntimeResult::ok : RuntimeResult::interrupt;
}

struct ScriptExchange {
  bool started = false;
  bool cancelled = false;
  bool invalid = false;
};

std::string SimulateScriptHost(void* opaque, std::string_view message) {
  auto& exchange = *static_cast<ScriptExchange*>(opaque);
  if (!exchange.started && message.starts_with("Q") &&
      message.find("https://api.example.invalid/fixture") != std::string_view::npos) {
    exchange.started = true;
    return R"({"pending":true})";
  }
  if (exchange.started && !exchange.cancelled && message == "P") {
    return R"({"pending":true})";
  }
  if (exchange.started && !exchange.cancelled && message == "X") {
    exchange.cancelled = true;
    return R"({"error":"cancelled"})";
  }
  exchange.invalid = true;
  return {};
}

RuntimeResult CheckScriptContract() {
  constexpr std::string_view script = R"JS(
    const {request, send, on, EVENT_NAMES, utils} = globalThis.lx;
    if (lx.version !== '2.0.0' || !lx.currentScriptInfo.rawScript.includes('fixture')) throw 1;
    on(EVENT_NAMES.request, ({source, action, info}) => new Promise((resolve, reject) => {
      if (source !== 'tx' || action !== 'musicUrl' || info.musicInfo.songmid !== 'fixture') {
        return reject();
      }
      const cancel = request('https://api.example.invalid/fixture', {}, () => reject());
      setTimeout(() => cancel(), 30);
      setTimeout(() => {
        if (utils.buffer.bufToString(utils.buffer.from('test'), 'base64') !== 'dGVzdA==') {
          reject();
        } else {
          resolve('https://media.example.invalid/fixture.wav');
        }
      }, 60);
    }));
    send(EVENT_NAMES.inited, {
      sources: {tx: {type: 'music', actions: ['musicUrl'], qualitys: ['128k']}},
    });
  )JS";
  constexpr std::string_view parameters = R"({
    "env":"mobile","info":{"name":"Fixture"},
    "event":{"source":"tx","action":"musicUrl","info":{"type":"128k","musicInfo":{"songmid":"fixture"}}}
  })";
  ScriptExchange exchange;
  const auto answer = RunLxScript(script, parameters, SimulateScriptHost, &exchange);
  return exchange.started && exchange.cancelled && !exchange.invalid &&
                 answer == R"({"url":"https://media.example.invalid/fixture.wav"})"
      ? RuntimeResult::ok : RuntimeResult::globals_or_promise;
}

struct Catalog {
  FixtureCatalog query;
  void* opaque;
  int count = 0;
};

JSValue FixtureRequest(JSContext* ctx, JSValueConst, int argc,
                       JSValueConst* argv) {
  auto& catalog = *static_cast<Catalog*>(JS_GetContextOpaque(ctx));
  int32_t request = 0;
  if (argc != 1 || !JS_IsNumber(argv[0]) ||
      JS_ToInt32(ctx, &request, argv[0]) < 0 || request != 1 ||
      ++catalog.count != 1 || catalog.query(catalog.opaque, request) != 1) {
    return JS_ThrowTypeError(ctx, "Fixture catalogue denied");
  }
  return JS_NewInt32(ctx, 1);
}

}  // namespace

RuntimeResult RunRuntimeFixtures() {
  for (const auto check : {CheckGlobalsAndPromise, CheckMemory, CheckInterrupt, CheckScriptContract}) {
    const auto result = check();
    if (result != RuntimeResult::ok) return result;
  }
  return RuntimeResult::ok;
}

int RunPlaybackFixture(bool timeout, FixtureCatalog query, void* opaque) {
  if (!query) return 91;
  Runtime runtime;
  if (!runtime) return 91;
  runtime.SetBudget(1s);
  auto* context = runtime.context();
  Catalog catalog{query, opaque};
  JS_SetContextOpaque(context, &catalog);
  const auto global = JS_GetGlobalObject(context);
  const auto bridge = JS_NewCFunction(context, FixtureRequest, "fixtureRequest", 1);
  const int installed = JS_SetPropertyStr(context, global, "fixtureRequest", bridge);
  JS_FreeValue(context, global);
  if (installed < 0) return 91;
  auto bootstrap = runtime.Eval(R"JS(
    let handler, ready;
    const lx = Object.freeze({
      EVENT_NAMES: Object.freeze({ request: 'request', inited: 'inited' }),
      on(name, callback) {
        if (name !== 'request' || handler || typeof callback !== 'function') {
          throw new TypeError('Unexpected fixture handler');
        }
        handler = callback;
      },
      send(name, payload) {
        if (name !== 'inited' || ready) throw new TypeError('Unexpected init');
        const tx = payload.sources.tx;
        ready = tx.type === 'music' && tx.actions.length === 1 &&
          tx.actions[0] === 'musicUrl' && tx.qualitys.length === 1 &&
          tx.qualitys[0] === '128k';
        if (!ready) throw new TypeError('Unsupported fixture');
      },
      request(url, options, callback) {
        if (url !== 'https://catalog.fixture.invalid/wave' ||
            options.method !== 'GET') throw new TypeError('Unexpected request');
        const reply = fixtureRequest(1);
        Promise.resolve(reply).then(body => callback(null, { statusCode: 200 }, body));
      },
    });
    const track = Object.freeze({ source: 'tx', action: 'musicUrl',
      info: Object.freeze({ type: '128k', musicInfo: Object.freeze({
        songmid: 'motifFixture', strMediaMid: 'motifFixture',
      }) }) });
    const address = 'https://raw.githubusercontent.com/jiaaro/pydub/' +
      '103e339d3bc7a9a58a9f1de65f7d8074659b5f5a/test/data/test-dc_offset.wav';
    const init = () => lx.send(lx.EVENT_NAMES.inited, {
      sources: { tx: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } }
    });
    function resolveFixture() {
      if (!ready || !handler) throw new TypeError('Fixture not initialized');
      return handler(track).then(result => { globalThis.checked = result === address; });
    }
    globalThis.checked = false;
  )JS");
  bool ok = !JS_IsException(bootstrap);
  JS_FreeValue(context, bootstrap);
  if (!ok) return 92;
  runtime.SetBudget(timeout ? 200ms : 2s);
  auto run = runtime.Eval(timeout ? R"JS(
    lx.on(lx.EVENT_NAMES.request, () => { while (true) {} });
    init();
    resolveFixture();
  )JS" : R"JS(
    lx.on(lx.EVENT_NAMES.request, ({ source, action, info }) => {
      if (source !== 'tx' || action !== 'musicUrl' || info.type !== '128k' ||
          info.musicInfo.strMediaMid !== 'motifFixture') throw new TypeError('Fixture track');
      return new Promise((resolve, reject) => {
        lx.request('https://catalog.fixture.invalid/wave', { method: 'GET' },
          (error, response, body) => {
            if (error || response.statusCode !== 200 || body !== 1) reject();
            else resolve(address);
          });
      });
    });
    init();
    resolveFixture();
  )JS");
  ok = !JS_IsException(run);
  JS_FreeValue(context, run);
  if (timeout) return !ok && runtime.interrupted() && catalog.count == 0 ? 90 : 93;
  if (!ok || !runtime.RunJobs() || catalog.count != 1) return 93;
  auto checked = runtime.Eval("globalThis.checked === true");
  ok = JS_IsBool(checked) && JS_ToBool(context, checked) == 1;
  JS_FreeValue(context, checked);
  return ok ? 0 : 94;
}

}  // namespace motif::lx_probe

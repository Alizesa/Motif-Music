#include "runtime_fixture.h"

#include <chrono>
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

}  // namespace

RuntimeResult RunRuntimeFixtures() {
  for (const auto check : {CheckGlobalsAndPromise, CheckMemory, CheckInterrupt}) {
    const auto result = check();
    if (result != RuntimeResult::ok) return result;
  }
  return RuntimeResult::ok;
}

}  // namespace motif::lx_probe

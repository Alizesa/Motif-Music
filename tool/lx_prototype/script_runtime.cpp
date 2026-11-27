#include "script_runtime.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <thread>

#include "quickjs.h"

namespace motif::lx_probe {
namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr char kPrelude[] =
#include "script_prelude.inc"
    ;
constexpr char kError[] = R"({"error":"script"})";

bool IsCancelCommand(std::string_view message, int issued) {
  if (message.size() < 2 || message[0] != 'X' || message[1] < '1' || message[1] > '9') return false;
  int id = 0;
  const auto end = message.data() + message.size();
  const auto [ptr, ec] = std::from_chars(message.data() + 1, end, id);
  return ec == std::errc{} && ptr == end && id <= issued;
}

struct ScriptRuntime {
  JSRuntime* runtime = JS_NewRuntime();
  JSContext* context = nullptr;
  Clock::time_point deadline = Clock::now() + std::chrono::seconds(kLxScriptTimeoutSeconds);
  int jobs = 0;

  ScriptRuntime() {
    if (!runtime) return;
    JS_SetMemoryLimit(runtime, 24 * 1024 * 1024);
    JS_SetMaxStackSize(runtime, 512 * 1024);
    JS_SetInterruptHandler(runtime, [](JSContext*, void* opaque) {
      return static_cast<const ScriptRuntime*>(opaque)->Expired() ? 1 : 0;
    }, this);
    context = JS_NewContext(runtime);
  }

  ~ScriptRuntime() {
    if (context) JS_FreeContext(context);
    if (runtime) JS_FreeRuntime(runtime);
  }

  bool Expired() const { return Clock::now() >= deadline; }

  bool DrainJobs() {
    JSContext* job_context = nullptr;
    while (jobs < 512 && !Expired()) {
      const int status = JS_ExecutePendingJob(runtime, &job_context);
      if (status <= 0) return status == 0;
      ++jobs;
    }
    return false;
  }
};

struct Value {
  JSContext* context;
  JSValue value;
  ~Value() { JS_FreeValue(context, value); }
};

std::string CopyMessage(JSContext* context, JSValueConst value) {
  if (!JS_IsString(value)) return {};
  size_t size = 0;
  const char* text = JS_ToCStringLen(context, &size, value);
  if (!text) return {};
  std::string result;
  if (size <= kLxMessageBytes) result.assign(text, size);
  JS_FreeCString(context, text);
  return result;
}
}  // namespace

std::string RunLxScript(std::string_view script, std::string_view parameters,
                        ScriptRequest request, void* opaque) {
  if (script.empty() || script.size() > kLxScriptBytes ||
      parameters.empty() || parameters.size() > kLxMessageBytes || !request) return kError;
  ScriptRuntime runtime;
  auto* context = runtime.context;
  if (!context) return kError;

  // QuickJS's parsers require a NUL past the input length.
  const std::string script_text(script);
  const std::string parameter_text(parameters);
  const Value configuration{context, JS_ParseJSON(context, parameter_text.c_str(),
      parameter_text.size(), "<lx-input>")};
  const Value make_runner{context, JS_Eval(context, kPrelude, sizeof(kPrelude) - 1,
      "<lx-prelude>", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT)};
  const Value source{context, JS_NewStringLen(context, script_text.data(), script_text.size())};
  if (JS_IsException(configuration.value) || !JS_IsFunction(context, make_runner.value) ||
      JS_IsException(source.value)) return kError;
  JSValue argv[]{configuration.value, source.value};
  const Value step{context, JS_Call(context, make_runner.value, JS_UNDEFINED, 2, argv)};
  if (!JS_IsFunction(context, step.value)) return kError;
  const Value evaluated{context, JS_Eval(context, script_text.c_str(), script_text.size(),
      "<lx-script>", JS_EVAL_TYPE_GLOBAL)};
  if (JS_IsException(evaluated.value)) return kError;

  std::string response;
  int requests = 0;
  for (int actions = 0; actions < kLxScriptExchangeLimit && !runtime.Expired(); ++actions) {
    if (!runtime.DrainJobs()) {
      if (runtime.Expired()) break;
      return kError;
    }
    Value argument{context, response.empty() ? JS_UNDEFINED
        : JS_NewStringLen(context, response.data(), response.size())};
    if (JS_IsException(argument.value)) return kError;
    const Value value{context, JS_Call(context, step.value, JS_UNDEFINED, 1, &argument.value)};
    if (runtime.Expired()) break;
    const auto message = CopyMessage(context, value.value);
    response.clear();
    if (message.empty()) return kError;
    if (message[0] == 'D') return message.substr(1);
    if (message == "S") {
      // LX Mobile waits 20s for this action, independent of an HTTP timeout.
      runtime.deadline = std::min(runtime.deadline, Clock::now() + 20s);
    } else if (message == "W") {
      std::this_thread::sleep_for(12ms);
    } else if (message[0] == 'Q' || message == "P" || IsCancelCommand(message, requests)) {
      if (message[0] == 'Q') ++requests; // bounded by the IPC action limit
      if (message == "P") std::this_thread::sleep_for(15ms);
      response = request(opaque, message);
      if (response.empty() || response.size() > kLxMessageBytes) return kError;
    } else if (message != "T") {
      return kError;
    }
  }
  return R"({"error":"timeout"})";
}
}  // namespace motif::lx_probe

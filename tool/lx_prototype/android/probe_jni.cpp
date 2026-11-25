#include <jni.h>

#ifndef MOTIF_LX_RUNTIME_ONLY
#include <dlfcn.h>

#include "media_fixture.h"
#endif
#include "runtime_fixture.h"
#include "script_runtime.h"

extern "C" JNIEXPORT jint JNICALL
Java_com_alizesa_motif_lxprobe_ProbeService_nativeRunFixture(JNIEnv*, jclass) {
  return static_cast<jint>(motif::lx_probe::RunRuntimeFixtures());
}

namespace {
struct CatalogBridge {
  JNIEnv* environment;
  jobject catalog;
  jmethodID query;
};

int ReadCatalog(void* opaque, int request) {
  const auto& bridge = *static_cast<CatalogBridge*>(opaque);
  auto* env = bridge.environment;
  const jint response = env->CallIntMethod(bridge.catalog, bridge.query, request);
  if (!env->ExceptionCheck()) return response;
  env->ExceptionClear();
  return -1;
}

struct ScriptBridge {
  JNIEnv* environment;
  jobject broker;
  jmethodID request;
};

std::string ReadBytes(JNIEnv* env, jbyteArray bytes, size_t maximum) {
  if (!bytes) return {};
  const auto count = env->GetArrayLength(bytes);
  if (count <= 0 || static_cast<size_t>(count) > maximum) return {};
  std::string result(static_cast<size_t>(count), '\0');
  env->GetByteArrayRegion(bytes, 0, count, reinterpret_cast<jbyte*>(result.data()));
  return env->ExceptionCheck() ? std::string{} : result;
}

jbyteArray NewBytes(JNIEnv* env, std::string_view value) {
  const auto length = static_cast<jsize>(value.size());
  const auto bytes = env->NewByteArray(length);
  if (bytes) {
    env->SetByteArrayRegion(bytes, 0, length,
                            reinterpret_cast<const jbyte*>(value.data()));
  }
  return bytes;
}

std::string RelayRequest(void* opaque, std::string_view message) {
  const auto& bridge = *static_cast<ScriptBridge*>(opaque);
  auto* env = bridge.environment;
  const auto bytes = NewBytes(env, message);
  if (!bytes || env->ExceptionCheck()) return {};
  const auto reply = static_cast<jbyteArray>(
      env->CallObjectMethod(bridge.broker, bridge.request, bytes));
  env->DeleteLocalRef(bytes);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return {};
  }
  auto result = ReadBytes(env, reply, motif::lx_probe::kLxMessageBytes);
  if (reply) env->DeleteLocalRef(reply);
  return result;
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_alizesa_motif_lxprobe_ProbeService_nativePlayback(
    JNIEnv* env, jclass, jboolean timeout, jobject catalog) {
  if (!catalog) return 91;
  const jclass type = env->GetObjectClass(catalog);
  if (!type) return 91;
  const jmethodID query = env->GetMethodID(type, "query", "(I)I");
  env->DeleteLocalRef(type);
  if (!query) return 91;
  CatalogBridge bridge{env, catalog, query};
  return motif::lx_probe::RunPlaybackFixture(timeout == JNI_TRUE, ReadCatalog, &bridge);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_alizesa_motif_lxprobe_ProbeService_nativeScript(
    JNIEnv* env, jclass, jbyteArray script, jbyteArray parameters, jobject broker) {
  if (!broker) return nullptr;
  try {
    const auto source = ReadBytes(env, script, motif::lx_probe::kLxScriptBytes);
    const auto data = ReadBytes(env, parameters, motif::lx_probe::kLxMessageBytes);
    if (env->ExceptionCheck()) return nullptr;
    const auto type = env->GetObjectClass(broker);
    if (!type) return nullptr;
    const auto method = env->GetMethodID(type, "request", "([B)[B");
    env->DeleteLocalRef(type);
    if (!method) return nullptr;
    ScriptBridge bridge{env, broker, method};
    const auto reply = motif::lx_probe::RunLxScript(source, data, RelayRequest, &bridge);
    return env->ExceptionCheck() ? nullptr : NewBytes(env, reply);
  } catch (...) {
    return nullptr;
  }
}

#ifndef MOTIF_LX_RUNTIME_ONLY
extern "C" JNIEXPORT jint JNICALL
Java_com_alizesa_motif_lxprobe_IsolationInstrumentation_nativeRunMediaFixture(JNIEnv*, jclass) {
  void* library = dlopen("libmpv_audio_kit.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) return 6;
  const int result = motif::lx_probe::RunMediaFixtures(library, dlsym);
  dlclose(library);
  return static_cast<jint>(result);
}
#endif

#include <jni.h>

#ifndef MOTIF_LX_RUNTIME_ONLY
#include <dlfcn.h>

#include "media_fixture.h"
#endif
#include "runtime_fixture.h"

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

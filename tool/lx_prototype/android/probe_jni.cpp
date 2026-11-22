#include <jni.h>
#include <dlfcn.h>

#include "media_fixture.h"
#include "runtime_fixture.h"

extern "C" JNIEXPORT jint JNICALL
Java_com_alizesa_motif_lxprobe_ProbeService_nativeRunFixture(JNIEnv*, jclass) {
  return static_cast<jint>(motif::lx_probe::RunRuntimeFixtures());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_alizesa_motif_lxprobe_IsolationInstrumentation_nativeRunMediaFixture(JNIEnv*, jclass) {
  void* library = dlopen("libmpv_audio_kit.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) return 6;
  const int result = motif::lx_probe::RunMediaFixtures(library, dlsym);
  dlclose(library);
  return static_cast<jint>(result);
}

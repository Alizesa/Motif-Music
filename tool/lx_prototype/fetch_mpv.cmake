cmake_minimum_required(VERSION 3.22)

# The same release and digests as mpv_audio_kit 0.7.2. These binaries are
# fixtures in the standalone CI project, never installed into Motif here.
if(MOTIF_MPV_PLATFORM STREQUAL "windows-x64")
  set(asset libmpv_windows-x86_64.dll)
  set(digest 1ba497325c21b83f23369f3e51f55792929454f278b2f81dc9f304a0b13eabaa)
elseif(MOTIF_MPV_PLATFORM STREQUAL "android-x86_64")
  set(asset libmpv_android-x86_64.so)
  set(digest 1eb936ee38b8ba97db4bd6d5f5d8979d7e69a427011ca65b73d1fdc40e9ea549)
elseif(MOTIF_MPV_PLATFORM STREQUAL "android-arm64")
  set(asset libmpv_android-arm64-v8a.so)
  set(digest 36884ee5c162f3a676cfbbebea737c3379981a372b56d3a0d72006ce560b0899)
else()
  message(FATAL_ERROR "Unknown libmpv fixture platform")
endif()
if(NOT IS_ABSOLUTE "${MOTIF_MPV_OUTPUT}")
  message(FATAL_ERROR "Set an absolute destination for the test fixture")
endif()
get_filename_component(parent "${MOTIF_MPV_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${parent}")
file(DOWNLOAD
  "https://github.com/ales-drnz/mpv_audio_kit/releases/download/libmpv-r26/${asset}"
  "${MOTIF_MPV_OUTPUT}"
  EXPECTED_HASH "SHA256=${digest}"
  TLS_VERIFY ON
  TIMEOUT 90)

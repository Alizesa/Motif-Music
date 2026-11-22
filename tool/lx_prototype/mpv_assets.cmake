# The same release and digests as mpv_audio_kit 0.7.2.
function(motif_mpv_asset platform out_url out_digest)
  if(platform STREQUAL "windows-x64")
    set(asset libmpv_windows-x86_64.dll)
    set(digest 1ba497325c21b83f23369f3e51f55792929454f278b2f81dc9f304a0b13eabaa)
  elseif(platform STREQUAL "android-x86_64")
    set(asset libmpv_android-x86_64.so)
    set(digest 1eb936ee38b8ba97db4bd6d5f5d8979d7e69a427011ca65b73d1fdc40e9ea549)
  elseif(platform STREQUAL "android-arm64")
    set(asset libmpv_android-arm64-v8a.so)
    set(digest 36884ee5c162f3a676cfbbebea737c3379981a372b56d3a0d72006ce560b0899)
  else()
    message(FATAL_ERROR "Unknown libmpv fixture platform")
  endif()
  set("${out_url}"
    "https://github.com/ales-drnz/mpv_audio_kit/releases/download/libmpv-r26/${asset}"
    PARENT_SCOPE)
  set("${out_digest}" "${digest}" PARENT_SCOPE)
endfunction()

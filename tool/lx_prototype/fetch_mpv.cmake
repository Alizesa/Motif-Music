cmake_minimum_required(VERSION 3.22)

include("${CMAKE_CURRENT_LIST_DIR}/mpv_assets.cmake")
motif_mpv_asset("${MOTIF_MPV_PLATFORM}" url digest)
if(NOT IS_ABSOLUTE "${MOTIF_MPV_OUTPUT}")
  message(FATAL_ERROR "Set an absolute destination for the test fixture")
endif()
get_filename_component(parent "${MOTIF_MPV_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${parent}")
file(DOWNLOAD
  "${url}"
  "${MOTIF_MPV_OUTPUT}"
  EXPECTED_HASH "SHA256=${digest}"
  TLS_VERIFY ON
  TIMEOUT 90)

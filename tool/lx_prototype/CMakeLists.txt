cmake_minimum_required(VERSION 3.22)
project(MotifLxPrototype LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()

# This standalone project is never included by the Motif application.
include(FetchContent)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_LIBC OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(QJS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(quickjs
  URL https://codeload.github.com/quickjs-ng/quickjs/tar.gz/d7215b0ad3fc2c562e8317fd9bca058fd4863804
  URL_HASH SHA256=a49defe70cbcae9226d9fac025af116e87ebae2440dcff1ca3c80b79e1cdef0b
  TLS_VERIFY TRUE
  TIMEOUT 90
  SOURCE_SUBDIR download-only
)
FetchContent_MakeAvailable(quickjs)
add_subdirectory("${quickjs_SOURCE_DIR}" "${quickjs_BINARY_DIR}" EXCLUDE_FROM_ALL)

add_library(lx_fixture STATIC runtime_fixture.cpp)
target_link_libraries(lx_fixture PRIVATE qjs)
target_include_directories(lx_fixture PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

include(mpv_headers.cmake)
add_library(lx_media_fixture STATIC media_fixture.cpp)
target_include_directories(lx_media_fixture PRIVATE "${MOTIF_MPV_INCLUDE}")
target_include_directories(lx_media_fixture PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

if(ANDROID)
  add_library(motif_lx_probe SHARED android/probe_jni.cpp)
  target_link_libraries(motif_lx_probe PRIVATE lx_fixture lx_media_fixture dl)
elseif(WIN32)
  if(NOT IS_ABSOLUTE "${MOTIF_LX_MPV_DLL}" OR NOT EXISTS "${MOTIF_LX_MPV_DLL}")
    message(FATAL_ERROR "Supply the pinned absolute MOTIF_LX_MPV_DLL fixture path")
  endif()
  add_executable(motif_lx_probe windows/probe.cpp)
  target_compile_definitions(motif_lx_probe PRIVATE
    UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
  target_link_libraries(motif_lx_probe PRIVATE lx_fixture advapi32 ole32 user32 userenv ws2_32)
  if(MINGW)
    target_link_options(motif_lx_probe PRIVATE -municode)
  endif()
  add_executable(motif_lx_media_probe windows/media_probe.cpp)
  target_compile_definitions(motif_lx_media_probe PRIVATE UNICODE _UNICODE NOMINMAX)
  target_link_libraries(motif_lx_media_probe PRIVATE lx_media_fixture)
  if(MINGW)
    target_link_options(motif_lx_media_probe PRIVATE -municode)
  endif()
  enable_testing()
  add_test(NAME lx_windows_isolation COMMAND motif_lx_probe)
  set_tests_properties(lx_windows_isolation PROPERTIES TIMEOUT 55)
  add_test(NAME lx_windows_controlled_media
           COMMAND motif_lx_media_probe "${MOTIF_LX_MPV_DLL}")
  set_tests_properties(lx_windows_controlled_media PROPERTIES TIMEOUT 35)
else()
  message(FATAL_ERROR "The isolation prototype targets Windows and Android")
endif()

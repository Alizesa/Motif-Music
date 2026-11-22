cmake_minimum_required(VERSION 3.22)

if(NOT IS_ABSOLUTE "${MOTIF_LX_WINDOWS_BUILD}" OR
   NOT IS_DIRECTORY "${MOTIF_LX_WINDOWS_BUILD}")
  message(FATAL_ERROR "Supply the absolute directory of the Windows Release probes")
endif()
set(package "${MOTIF_LX_WINDOWS_PACKAGE}")
if(NOT IS_ABSOLUTE "${package}" OR EXISTS "${package}" OR IS_SYMLINK "${package}")
  message(FATAL_ERROR "Supply a fresh absolute package directory")
endif()
if(NOT IS_ABSOLUTE "${MOTIF_LX_MPV_DLL}")
  message(FATAL_ERROR "Supply the absolute path of the pinned Windows libmpv fixture")
endif()
string(LENGTH "${MOTIF_LX_SOURCE_COMMIT}" commit_length)
if(NOT commit_length EQUAL 40 OR NOT MOTIF_LX_SOURCE_COMMIT MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "Supply the full source commit for the Windows probes")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/mpv_assets.cmake")
motif_mpv_asset(windows-x64 mpv_url mpv_digest)
file(SHA256 "${MOTIF_LX_MPV_DLL}" actual_digest)
if(NOT actual_digest STREQUAL mpv_digest)
  message(FATAL_ERROR "Windows libmpv fixture hash does not match the pinned asset")
endif()

file(MAKE_DIRECTORY "${package}")
set(sums "")
foreach(probe IN ITEMS motif_lx_probe motif_lx_worker motif_lx_media_probe)
  set(exe "${probe}.exe")
  file(COPY_FILE "${MOTIF_LX_WINDOWS_BUILD}/${exe}" "${package}/${exe}")
  file(SHA256 "${package}/${exe}" digest)
  string(APPEND sums "${digest}  ${exe}\n")
endforeach()
file(COPY
  "${CMAKE_CURRENT_LIST_DIR}/licenses/quickjs-ng"
  "${CMAKE_CURRENT_LIST_DIR}/licenses/mpv-client-api"
  DESTINATION "${package}/licenses")

function(check_packaged_probe probe timeout)
  execute_process(
    COMMAND "${package}/${probe}.exe" ${ARGN}
    WORKING_DIRECTORY "${package}"
    TIMEOUT "${timeout}"
    RESULT_VARIABLE status
    OUTPUT_VARIABLE output
    ERROR_VARIABLE diagnostics)
  file(WRITE "${package}/${probe}.log" "Exit: ${status}\n${output}${diagnostics}")
  if(NOT status STREQUAL "0" OR NOT output MATCHES "(^|[\r\n])PASS ")
    message(FATAL_ERROR "Packaged ${probe} failed (${status})\n${output}${diagnostics}")
  endif()
  message(STATUS "Packaged ${probe} passed")
endfunction()

# Run from the package directory. libmpv is supplied separately by upstream.
check_packaged_probe(motif_lx_probe 55)
check_packaged_probe(motif_lx_media_probe 35 "${MOTIF_LX_MPV_DLL}")

file(WRITE "${package}/BUILD-INFO.txt"
  "Source commit: ${MOTIF_LX_SOURCE_COMMIT}\nTarget: Windows x64 Release\n"
  "libmpv fixture: ${mpv_url}\nlibmpv SHA-256: ${mpv_digest}\n")
file(WRITE "${package}/SHA256SUMS.txt" "${sums}")
string(CONFIGURE [=[
Motif LX prototype for Windows x64

Extract all files together to a writable folder and open Windows PowerShell
there as your usual desktop user. Paste the following commands. No build tools
or Motif installation are needed. The media probe uses the pinned upstream
libmpv fixture; you can also place a matching copy at .\libmpv.dll beforehand.

Get-Content -LiteralPath .\BUILD-INFO.txt
foreach ($motifEntry in Get-Content -LiteralPath .\SHA256SUMS.txt) {
    $motifExpected, $motifName = $motifEntry -split '  ', 2
    if ((Get-FileHash -LiteralPath $motifName -Algorithm SHA256 -ErrorAction Stop).Hash -ne $motifExpected) {
        throw "Probe hash mismatch: $motifName"
    }
}

& .\motif_lx_probe.exe
if ($LASTEXITCODE -ne 0) { throw "Isolation probe exit: $LASTEXITCODE" }

$motifFixture = Join-Path (Get-Location).Path 'libmpv.dll'
if (-not (Test-Path -LiteralPath $motifFixture -PathType Leaf)) {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop -Uri '@mpv_url@' -OutFile $motifFixture
}
if ((Get-FileHash -LiteralPath $motifFixture -Algorithm SHA256 -ErrorAction Stop).Hash -ne '@mpv_digest@') {
    throw 'The libmpv fixture does not match the pinned SHA-256.'
}
& .\motif_lx_media_probe.exe $motifFixture
if ($LASTEXITCODE -ne 0) { throw "Media probe exit: $LASTEXITCODE" }

Both probes should print PASS and exit 0. The included .log files are the CI
results; record the console output and Windows version for the desktop run.
The media samples are synthetic. They do not check audible output.
]=] readme @ONLY)
file(WRITE "${package}/README.txt" "${readme}")

set(MOTIF_MPV_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/mpv-headers")
file(MAKE_DIRECTORY "${MOTIF_MPV_INCLUDE}/mpv")

function(motif_mpv_header name digest)
  set(path "${MOTIF_MPV_INCLUDE}/mpv/${name}")
  if(EXISTS "${path}")
    file(SHA256 "${path}" current)
    if(current STREQUAL digest)
      return()
    endif()
  endif()
  file(DOWNLOAD
    "https://raw.githubusercontent.com/mpv-player/mpv/v0.42.0/include/mpv/${name}"
    "${path}"
    EXPECTED_HASH "SHA256=${digest}"
    TLS_VERIFY ON
    TIMEOUT 40)
endfunction()

motif_mpv_header(client.h 3da9b8c61c3fb4e2d76bd248cebf72f3ee830331411b71a76adbd5e05660cc50)
motif_mpv_header(stream_cb.h 188e58b6d14383e15a5dffdc4ecebbdfbf2e412b9c099ff21b571f747a8ce32d)

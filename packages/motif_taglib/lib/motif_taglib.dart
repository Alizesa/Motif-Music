// ignore_for_file: non_constant_identifier_names

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> motif_taglib_read_path(Pointer<Utf8> path);

@Native<Pointer<Utf8> Function(Int32)>()
external Pointer<Utf8> motif_taglib_read_fd(int fd);

@Native<Void Function(Pointer<Utf8>)>()
external void motif_taglib_free(Pointer<Utf8> value);

/// Synchronous FFI: call only from a background isolate. Never writes audio tags.
Map<String, Object?> readTagLib({String? path, int? descriptor}) {
  if ((path == null) == (descriptor == null)) {
    throw ArgumentError('Provide one path or descriptor');
  }
  Pointer<Utf8> result;
  if (path != null) {
    final nativePath = path.toNativeUtf8();
    try {
      result = motif_taglib_read_path(nativePath);
    } finally {
      malloc.free(nativePath);
    }
  } else {
    result = motif_taglib_read_fd(descriptor!);
  }
  if (result == nullptr) {
    throw const FormatException('TagLib could not parse the audio file');
  }
  try {
    return (jsonDecode(result.toDartString()) as Map).cast<String, Object?>();
  } finally {
    motif_taglib_free(result);
  }
}

@Native<Void Function(Int32)>(symbol: 'motif_taglib_close_fd')
external void closeTagLibDescriptor(int descriptor);

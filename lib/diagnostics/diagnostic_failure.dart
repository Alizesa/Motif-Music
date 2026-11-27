import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:mpv_audio_kit/mpv_audio_kit.dart' show MpvCommandException;

import '../audio/controlled_pcm.dart';
import '../downloads/download_storage_error.dart';
import '../library/domain/library_playback_error.dart';
import '../online/domain/online_error.dart';
import '../online/lx/fixture/lx_fixture_wave.dart';
import '../online/lx/lx_request_error.dart';
import 'diagnostic_recorder.dart';

enum _Failure {
  cancelled,
  timeout,
  fileSystem,
  connection,
  io,
  destination,
  platform,
  nativeCommand,
  malformed,
  illegalState,
  invalidArgument,
  unknown,
}

/// Extract a fixed category/numeric code from known failures. Never render
/// [error], [PlatformException.details] or a native error message to a report.
DiagnosticFacts diagnosticFailure(Object error) => {
  DiagnosticField.reason: switch (error) {
    DownloadStorageException(:final problem) => problem,
    LxRequestException(:final reason) => reason,
    OnlineException(:final kind) => kind,
    LibraryPlaybackException(:final kind) => kind,
    FixtureMediaException(:final kind) => kind,
    PcmCancelled() => _Failure.cancelled,
    TimeoutException() => _Failure.timeout,
    FileSystemException() => _Failure.fileSystem,
    SocketException() => _Failure.connection,
    IOException() => _Failure.io,
    PlatformException(code: 'download_io' || 'download_directory') =>
      _Failure.destination,
    PlatformException() => _Failure.platform,
    MpvCommandException() => _Failure.nativeCommand,
    FormatException() => _Failure.malformed,
    StateError() => _Failure.illegalState,
    ArgumentError() => _Failure.invalidArgument,
    _ => _Failure.unknown,
  },
  DiagnosticField.code: switch (error) {
    DownloadStorageException(:final osCode) => osCode,
    MpvCommandException(:final code) => code,
    FileSystemException(:final osError) => osError?.errorCode,
    SocketException(:final osError) => osError?.errorCode,
    _ => null,
  },
};

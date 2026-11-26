import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Debugging vocabulary, not a sink for arbitrary strings, URLs, or payloads.
enum DiagnosticEvent {
  lifecycle,
  playbackRequested,
  localMatch,
  localFallback,
  sourceRequest,
  sourceFallback,
  sourceReady,
  sourceFailure,
  lxCatalog,
  lxScript,
  lxApiResponse,
  lxApiFailure,
  lxMediaResponse,
  lxMediaFailure,
  lxMediaReady,
  engineOpening,
  playbackReady,
  playbackFailed,
  playbackCancelled,
  playbackAction,
  playbackActionFailed,
  controlledRevoked,
  nativeBuffering,
  nativeAudioFormat,
  nativePlaying,
  nativeEnd,
  nativeError,
  nativeLogError,
  controlledReadFailure,
  controlledDecoderFailure,
  downloadRequested,
  downloadBody,
  downloadSaving,
  downloadFinished,
  downloadCleanupFailure,
}

enum DiagnosticField {
  state,
  stage,
  reason,
  action,
  code,
  source,
  sourceIndex,
  sourceCount,
  subsystem,
  quality,
  candidates,
  candidate,
  status,
  redirects,
  elapsedMs,
  medium,
  ranged,
  offset,
  seekable,
  positionMs,
  durationMs,
  buffering,
  playing,
  playWhenReady,
  loading,
  ready,
  sampleRate,
  channels,
  sampleFormat,
  outputRate,
  outputState,
  audioBitrate,
  mpvMajor,
  mpvMinor,
  mpvPatch,
  volume,
  gainDb,
  queueSize,
  queueIndex,
  hasMedia,
  readError,
  skippedSegments,
  task,
  attempt,
  taskCount,
  active,
  bytes,
  totalBytes,
  directorySelected,
  lxAvailable,
}

enum DiagnosticOperation { playback, download }

enum DiagnosticSource { qq, lx, other }

enum DiagnosticMedium { file, directStream, mp3, flac, wave }

enum DiagnosticStage { preferences, resolve, engine, directory, transfer, save }

enum DiagnosticAction { play, pause, next, previous, seek, retry }

enum DiagnosticResult {
  started,
  succeeded,
  failed,
  cancelled,
  skipped,
  mismatched,
}

enum DiagnosticSection { app, playback, player, downloads }

typedef DiagnosticFacts = Map<DiagnosticField, Object?>;

/// One attempt across async boundaries. Clearing/disabling recording expires
/// outstanding traces, so late work cannot reappear in a new capture.
final class DiagnosticTrace {
  DiagnosticTrace._(this._recorder, this._generation, this._operation, this.id);
  final DiagnosticRecorder _recorder;
  final int _generation;
  final DiagnosticOperation _operation;
  final int id;
  final _clock = Stopwatch()..start();

  bool get active => _recorder.enabled && _recorder._generation == _generation;

  void record(DiagnosticEvent event, [DiagnosticFacts facts = const {}]) {
    if (!active) return;
    _recorder._record(event, facts, this);
  }
}

final class DiagnosticReport {
  const DiagnosticReport(this.fileName, this.bytes);
  final String fileName;
  final Uint8List bytes;
}

/// Session-only capture, explicitly enabled by the user. No disk/network I/O,
/// no raw exception or runtime log text, and no notifications per log entry.
final class DiagnosticRecorder extends ChangeNotifier {
  static const maxEvents = 512;
  static const _maxEventJsonBytes = 96 * 1024;
  final _events = ListQueue<({Map<String, Object?> value, int bytes})>();
  final _clock = Stopwatch();
  DateTime? _startedAt;
  int _bytes = 0;
  int _discarded = 0;
  int _generation = 0;
  int _nextOperation = 0;
  bool _enabled = false;
  bool _closed = false;

  bool get enabled => _enabled;
  int get captureGeneration => _generation;

  void setEnabled(bool value) {
    if (_closed || value == _enabled) return;
    _enabled = value;
    _reset();
    notifyListeners();
  }

  void clear() {
    if (!enabled) return;
    _reset();
  }

  void _reset() {
    _generation++;
    _nextOperation = 0;
    _events.clear();
    _bytes = 0;
    _discarded = 0;
    _startedAt = enabled ? DateTime.now().toUtc() : null;
    _clock
      ..stop()
      ..reset();
    if (enabled) _clock.start();
  }

  DiagnosticTrace? begin(DiagnosticOperation operation) => !enabled
      ? null
      : DiagnosticTrace._(this, _generation, operation, ++_nextOperation);

  void record(DiagnosticEvent event, [DiagnosticFacts facts = const {}]) {
    if (enabled) _record(event, facts, null);
  }

  void _record(
    DiagnosticEvent event,
    DiagnosticFacts facts,
    DiagnosticTrace? trace,
  ) {
    final value = <String, Object?>{
      'atMs': _clock.elapsedMilliseconds,
      if (trace != null) ...{
        'operation': trace._operation.name,
        'operationId': trace.id,
        'operationMs': trace._clock.elapsedMilliseconds,
      },
      'event': event.name,
      ..._safeFacts(facts),
    };
    // Accepted values are primitives or compile-time enum names; there are no
    // variable strings. Track compact size as well as row count.
    final bytes = utf8.encode(jsonEncode(value)).length;
    while (_events.isNotEmpty &&
        (_events.length >= maxEvents || _bytes + bytes > _maxEventJsonBytes)) {
      _bytes -= _events.removeFirst().bytes;
      _discarded++;
    }
    _events.addLast((value: value, bytes: bytes));
    _bytes += bytes;
  }

  DiagnosticReport export(Map<DiagnosticSection, DiagnosticFacts> snapshot) {
    final startedAt = _startedAt;
    if (!enabled || startedAt == null) throw StateError('Diagnostics disabled');
    final now = DateTime.now().toUtc();
    final time = now.toIso8601String();
    final json = const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'app': 'Motif',
      'captureStartedAt': startedAt.toIso8601String(),
      'exportedAt': time,
      'environment': _environment(),
      'retainedEvents': _events.length,
      'discardedEvents': _discarded,
      'snapshot': {
        for (final entry in snapshot.entries)
          entry.key.name: _safeFacts(entry.value),
      },
      'events': _events.map((row) => row.value).toList(growable: false),
    });
    final stamp = time.substring(0, 19).replaceAll(RegExp(r'[-:]'), '');
    return DiagnosticReport(
      'motif-diagnostics-${stamp}Z.json',
      Utf8Encoder().convert('$json\n'),
    );
  }

  @override
  void dispose() {
    _closed = true;
    _enabled = false;
    _reset();
    super.dispose();
  }
}

/// Do not stringify arbitrary objects, even if their key is known. Sensitive
/// text is excluded at capture as well as in the exported snapshot.
Map<String, Object?> _safeFacts(DiagnosticFacts facts) => {
  for (final MapEntry(:key, :value) in facts.entries)
    if (value is Enum ||
        value is bool ||
        value is int ||
        value is double && value.isFinite)
      key.name: value is Enum ? value.name : value,
};

Map<String, String> _environment() {
  const revision = String.fromEnvironment('MOTIF_BUILD_SHA');
  const appVersion = String.fromEnvironment('FLUTTER_BUILD_NAME');
  const buildNumber = String.fromEnvironment('FLUTTER_BUILD_NUMBER');
  const flutter = String.fromEnvironment('FLUTTER_VERSION');
  final operatingSystemVersion = Platform.operatingSystemVersion;
  final platformVersion = _version(operatingSystemVersion);
  final platformBuild = RegExp(
    r'\b(?:build|api)\s+([0-9]{1,7})\b',
    caseSensitive: false,
  ).firstMatch(operatingSystemVersion)?[1];
  final flutterVersion = _version(flutter);
  final dartVersion = _version(Platform.version);
  return {
    'platform': Platform.operatingSystem,
    'architecture': Abi.current().toString(),
    'mode': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    if (RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(revision))
      'sourceRevision': revision,
    'appVersion': ?_version(appVersion),
    if (RegExp(r'^[0-9]{1,12}(?:\.[0-9]{1,6}){0,3}$').hasMatch(buildNumber))
      'buildNumber': buildNumber,
    'osVersion': ?platformVersion,
    'osBuildOrApi': ?platformBuild,
    'flutter': ?flutterVersion,
    'dart': ?dartVersion,
  };
}

String? _version(String input) =>
    RegExp(r'\b[0-9]{1,6}(?:\.[0-9]{1,6}){1,3}\b').firstMatch(input)?[0];

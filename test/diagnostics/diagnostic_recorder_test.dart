import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/diagnostics/diagnostic_failure.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/online/lx/lx_request_error.dart';

enum _TestState { safe }

Map<String, dynamic> report(
  DiagnosticRecorder recorder, [
  Map<DiagnosticSection, DiagnosticFacts> snapshot = const {},
]) =>
    jsonDecode(utf8.decode(recorder.export(snapshot).bytes))
        as Map<String, dynamic>;

void main() {
  test(
    'opt-in only, re-enabling discards earlier events and invalidates work',
    () {
      final recorder = DiagnosticRecorder();
      addTearDown(recorder.dispose);
      expect(recorder.enabled, isFalse);
      expect(recorder.begin(DiagnosticOperation.playback), isNull);
      recorder.record(DiagnosticEvent.lifecycle);
      expect(() => recorder.export({}), throwsStateError);
      recorder.setEnabled(true);
      final old = recorder.begin(DiagnosticOperation.playback)!;
      expect(report(recorder)['events'], isEmpty);
      old.record(DiagnosticEvent.playbackRequested);
      expect(report(recorder)['retainedEvents'], 1);
      recorder.setEnabled(false);
      expect(old.active, isFalse);
      recorder.setEnabled(true);
      old.record(DiagnosticEvent.playbackFailed);
      expect(report(recorder)['events'], isEmpty);
      expect(recorder.begin(DiagnosticOperation.download)!.id, 1);
    },
  );

  test('clear invalidates active traces and does not change enabled state', () {
    final recorder = DiagnosticRecorder()..setEnabled(true);
    addTearDown(recorder.dispose);
    final earlier = recorder.begin(DiagnosticOperation.playback)!;
    earlier.record(DiagnosticEvent.playbackRequested);
    recorder.clear();
    earlier.record(DiagnosticEvent.nativeEnd);
    expect(recorder.enabled, isTrue);
    expect(report(recorder)['events'], isEmpty);
    final fresh = recorder.begin(DiagnosticOperation.download)!;
    fresh.record(DiagnosticEvent.downloadRequested, {DiagnosticField.task: 4});
    final event = (report(recorder)['events'] as List).single as Map;
    expect(event['operation'], 'download');
    expect(event['operationId'], fresh.id);
    expect(event['task'], 4);
    expect(event['atMs'], isA<int>());
    expect(event['operationMs'], isA<int>());
  });

  test(
    'export is bounded by both rows and bytes and retains the newest events',
    () {
      final recorder = DiagnosticRecorder()..setEnabled(true);
      addTearDown(recorder.dispose);
      for (var i = 0; i < 3000; i++) {
        recorder.record(DiagnosticEvent.nativeBuffering, {
          DiagnosticField.status: i,
        });
      }
      var json = report(recorder);
      expect(json['retainedEvents'], DiagnosticRecorder.maxEvents);
      expect(json['discardedEvents'], 3000 - DiagnosticRecorder.maxEvents);
      expect((json['events'] as List).last['status'], 2999);
      recorder.clear();
      final trace = recorder.begin(DiagnosticOperation.playback)!;
      for (var i = 0; i < 700; i++) {
        trace.record(DiagnosticEvent.playbackFailed, {
          for (final field in DiagnosticField.values) field: i,
        });
      }
      json = report(recorder);
      expect(json['retainedEvents'], lessThan(DiagnosticRecorder.maxEvents));
      expect(json['retainedEvents'] + json['discardedEvents'], 700);
      expect((json['events'] as List).last['status'], 699);
      expect(recorder.export({}).bytes.length, lessThan(200 * 1024));
    },
  );

  test(
    'raw exceptions, strings and containers cannot enter events or snapshots',
    () {
      final recorder = DiagnosticRecorder()..setEnabled(true);
      addTearDown(recorder.dispose);
      const sensitive = 'https://example.test/song?token=do-not-export';
      final opaque = _OpaqueError();
      final data = {
        DiagnosticField.reason: sensitive,
        DiagnosticField.source: opaque,
        DiagnosticField.medium: ['Cookie=do-not-export'],
        DiagnosticField.state: _TestState.safe,
        DiagnosticField.positionMs: double.nan,
        DiagnosticField.durationMs: 16000,
      };
      recorder.record(DiagnosticEvent.nativeError, data);
      recorder.record(
        DiagnosticEvent.downloadFinished,
        diagnosticFailure(
          PlatformException(
            code: 'download_io',
            message: sensitive,
            details: {'path': r'C:\Users\Private'},
          ),
        ),
      );
      recorder.record(
        DiagnosticEvent.lxApiFailure,
        diagnosticFailure(const LxRequestException(LxRequestFailure.tls)),
      );
      recorder.record(
        DiagnosticEvent.playbackFailed,
        diagnosticFailure(
          FileSystemException(
            sensitive,
            r'C:\Users\Private',
            const OSError('private', 5),
          ),
        ),
      );
      final output = recorder.export({DiagnosticSection.playback: data});
      final text = utf8.decode(output.bytes);
      final json = jsonDecode(text) as Map;
      final events = json['events'] as List;
      expect(text, isNot(contains('do-not-export')));
      expect(text, isNot(contains('Private')));
      expect(text, isNot(contains('http')));
      expect(json['snapshot']['playback'], {
        'state': 'safe',
        'durationMs': 16000,
      });
      expect(events[1]['reason'], 'destination');
      expect(events[2]['reason'], 'tls');
      expect(events[3]['code'], 5);
      final environment = json['environment'] as Map;
      expect(environment['platform'], Platform.operatingSystem);
      const revision = String.fromEnvironment('MOTIF_BUILD_SHA');
      expect(
        environment['sourceRevision'],
        revision.isEmpty ? isNull : revision,
      );
      expect(
        output.fileName,
        matches(r'^motif-diagnostics-\d{8}T\d{6}Z\.json$'),
      );
    },
  );
}

final class _OpaqueError {
  @override
  String toString() => throw StateError('Must never stringify input');
}

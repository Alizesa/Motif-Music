import 'dart:async';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/android_saf_library_source.dart';
import 'package:motif/library/platform/library_platform_source.dart';

const _channel = MethodChannel('motif/library_scanner');
const _root = FileLocation(
  platform: LibraryPlatform.android,
  key: 'provider|music',
  locator: 'content://provider/tree/music',
);

Map<String, Object?> _file([String name = 'song.M4A']) => {
  'key': 'provider|music/$name',
  'locator': 'content://provider/tree/music/document/music%2F$name',
  'fileName': name,
  'sizeBytes': 42,
  'modifiedMs': 100,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = AndroidSafLibrarySource();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late FilePickerPlatform originalPicker;

  void respond(FutureOr<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  Stream<List<ObservedAudioFile>> scan({
    FileLocation root = _root,
    LibraryScanCancellation? cancellation,
  }) => source.scanBatches(
    root,
    cancellation: cancellation ?? LibraryScanCancellation(),
  );

  setUp(() {
    calls = [];
    originalPicker = FilePickerPlatform.instance;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    FilePickerPlatform.instance = originalPicker;
  });

  test(
    'pulls one batch at a time and completes without cancellation',
    () async {
      var requests = 0;
      respond((call) {
        if (call.method != 'nextBatch') return null;
        requests++;
        return requests == 1
            ? {
                'type': 'batch',
                'files': [_file()],
              }
            : {'type': 'complete'};
      });
      final iterator = StreamIterator(scan());
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.single.fileName, 'song.M4A');
      expect(iterator.current.single.metadata, isNull);
      expect(iterator.current.single.sizeBytes, 42);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1, reason: 'Consumer has not requested the next batch.');
      expect(await iterator.moveNext(), isFalse);
      await iterator.cancel();
      expect(calls.map((call) => call.method), [
        'startScan',
        'nextBatch',
        'nextBatch',
      ]);
      final start = calls.first.arguments as Map;
      expect(start['extensions'], containsAll(['oga', 'alac', 'opus', 'wma']));
    },
  );

  test('concurrent roots keep independent scan IDs and responses', () async {
    final roots = <String, String>{};
    final emitted = <String>{};
    respond((call) {
      final arguments = call.arguments as Map;
      final id = arguments['scanId'] as String;
      if (call.method == 'startScan') {
        roots[id] = arguments['treeUri'] as String;
        return null;
      }
      if (call.method == 'nextBatch') {
        if (!emitted.add(id)) return {'type': 'complete'};
        final name = roots[id]!.endsWith('other') ? 'other.flac' : 'song.M4A';
        return {
          'type': 'batch',
          'files': [_file(name)],
        };
      }
      return null;
    });
    final results = await Future.wait([
      scan().toList(),
      scan(
        root: const FileLocation(
          platform: LibraryPlatform.android,
          key: 'provider|other',
          locator: 'content://provider/tree/other',
        ),
      ).toList(),
    ]);
    expect(roots, hasLength(2));
    expect(results[0].single.single.fileName, 'song.M4A');
    expect(results[1].single.single.fileName, 'other.flac');
    expect(calls.where((call) => call.method == 'cancelScan'), isEmpty);
  });

  test(
    'directory selection requests a persistent read-only SAF grant',
    () async {
      final picker = _DirectoryPicker(Uri.parse(_root.locator));
      FilePickerPlatform.instance = picker;
      respond(
        (call) => switch (call.method) {
          'persistedTrees' => <String>[],
          'describeTree' => {'key': _root.key, 'displayName': 'Music'},
          _ => null,
        },
      );
      final selected = await source.pickDirectory();
      expect(selected!.location.locator, _root.locator);
      expect(selected.location.key, _root.key);
      final options = (picker.options! as FilePickerAndroidOptions).safOptions;
      expect(options.accessMode, AndroidSAFAccessMode.readOnly);
      expect(options.persistGrant, isTrue);
      expect(options.copyToCache, isFalse);
      expect(calls.map((call) => call.method), [
        'persistedTrees',
        'describeTree',
      ]);
    },
  );

  for (final existing in [true, false]) {
    for (final invalidDetails in [true, false]) {
      test(
        'failed inspection preserves prior grant=$existing, invalid details=$invalidDetails',
        () async {
          FilePickerPlatform.instance = _DirectoryPicker(
            Uri.parse(_root.locator),
          );
          respond((call) {
            if (call.method == 'persistedTrees') {
              return existing ? [_root.locator] : <String>[];
            }
            if (call.method == 'describeTree') {
              if (invalidDetails) return {'displayName': 'Music'};
              throw PlatformException(code: 'scan_failed');
            }
            return null;
          });
          await expectLater(
            source.pickDirectory(),
            throwsA(isA<LibraryTraversalException>()),
          );
          expect(
            calls.where((call) => call.method == 'releaseTree'),
            hasLength(existing ? 0 : 1),
          );
        },
      );
    }
  }

  test('cancelled picker leaves all existing grants untouched', () async {
    FilePickerPlatform.instance = _DirectoryPicker(null);
    respond((call) => call.method == 'persistedTrees' ? [_root.locator] : null);
    expect(await source.pickDirectory(), isNull);
    expect(calls.map((call) => call.method), ['persistedTrees']);
  });

  test('root removal releases only its own grant', () async {
    respond((_) => null);
    await source.releaseDirectory(_root);
    expect(calls.single.method, 'releaseTree');
    expect((calls.single.arguments as Map)['treeUri'], _root.locator);
  });
  final malformed = <String, Object?>{
    'null response': null,
    'unknown response': {'type': 'error'},
    'completion with files': {
      'type': 'complete',
      'files': [_file()],
    },
    'empty batch': {'type': 'batch', 'files': []},
    'oversized batch': {
      'type': 'batch',
      'files': List.generate(201, (_) => _file()),
    },
    'non-map row': {
      'type': 'batch',
      'files': [_file(), 42],
    },
    'missing key': {
      'type': 'batch',
      'files': [
        {..._file(), 'key': ''},
      ],
    },
    'file URI': {
      'type': 'batch',
      'files': [
        {..._file(), 'locator': 'file:///music/song.M4A'},
      ],
    },
    'unsupported extension': {
      'type': 'batch',
      'files': [_file('cover.jpg')],
    },
    'fractional size': {
      'type': 'batch',
      'files': [
        {..._file(), 'sizeBytes': 2.5},
      ],
    },
    'negative timestamp': {
      'type': 'batch',
      'files': [
        {..._file(), 'modifiedMs': -1},
      ],
    },
  };
  for (final entry in malformed.entries) {
    test(
      'rejects ${entry.key} and cancels without emitting a partial batch',
      () async {
        respond((call) => call.method == 'nextBatch' ? entry.value : null);
        var batches = 0;
        await expectLater(
          scan().map((batch) {
            batches++;
            return batch;
          }).drain<void>(),
          throwsA(isA<LibraryTraversalException>()),
        );
        expect(batches, 0);
        expect(calls.last.method, 'cancelScan');
      },
    );
  }

  test('unknown stats remain null for pending metadata', () async {
    var emitted = false;
    respond((call) {
      if (call.method != 'nextBatch') return null;
      if (emitted) return {'type': 'complete'};
      emitted = true;
      return {
        'type': 'batch',
        'files': [
          {..._file(), 'sizeBytes': null, 'modifiedMs': null},
        ],
      };
    });
    final file = (await scan().toList()).single.single;
    expect(file.sizeBytes, isNull);
    expect(file.modifiedMs, isNull);
  });

  for (final code in ['permission_revoked', 'scan_failed']) {
    test(
      '$code ends the scan with the appropriate root access state',
      () async {
        respond((call) {
          if (call.method == 'nextBatch') {
            throw PlatformException(code: code, message: 'provider error');
          }
          return null;
        });
        await expectLater(
          scan().toList(),
          throwsA(
            isA<LibraryTraversalException>().having(
              (error) => error.rootAccessRevoked,
              'rootAccessRevoked',
              code == 'permission_revoked',
            ),
          ),
        );
        expect(calls.last.method, 'cancelScan');
      },
    );
  }

  test('pre-cancelled scans never start a native traversal', () async {
    respond((_) => null);
    final cancellation = LibraryScanCancellation()..cancel();
    await expectLater(
      scan(cancellation: cancellation).toList(),
      throwsA(isA<LibraryScanCancelledException>()),
    );
    expect(calls, isEmpty);
  });

  for (final method in ['startScan', 'nextBatch']) {
    test(
      'cancels while $method is blocked and consumes its late error',
      () async {
        final reached = Completer<void>();
        final blocked = Completer<Object?>();
        respond((call) {
          if (call.method == method) {
            reached.complete();
            return blocked.future;
          }
          return null;
        });
        final cancellation = LibraryScanCancellation();
        final finished = expectLater(
          scan(cancellation: cancellation).toList(),
          throwsA(isA<LibraryScanCancelledException>()),
        );
        await reached.future;
        cancellation.cancel();
        await finished;
        expect(calls.where((call) => call.method == 'cancelScan'), isNotEmpty);
        blocked.completeError(PlatformException(code: 'scan_cancelled'));
        await Future<void>.delayed(Duration.zero);
      },
    );
  }

  test(
    'consumer cancellation closes the native scan before another pull',
    () async {
      respond(
        (call) => call.method == 'nextBatch'
            ? {
                'type': 'batch',
                'files': [_file()],
              }
            : null,
      );
      await for (final batch in scan()) {
        expect(batch, hasLength(1));
        break;
      }
      expect(calls.map((call) => call.method), [
        'startScan',
        'nextBatch',
        'cancelScan',
      ]);
    },
  );

  test('cancellation listeners detach after completed operations', () {
    final cancellation = LibraryScanCancellation();
    var disposedCalls = 0;
    var activeCalls = 0;
    for (var i = 0; i < 1000; i++) {
      final dispose = cancellation.onCancel(() => disposedCalls++);
      dispose();
    }
    cancellation.onCancel(() => activeCalls++);
    cancellation.cancel();
    cancellation.cancel();
    expect(disposedCalls, 0);
    expect(activeCalls, 1);
    cancellation.onCancel(() => activeCalls++);
    expect(activeCalls, 2);
  });
}

class _DirectoryPicker extends FilePickerPlatform {
  _DirectoryPicker(this.uri);

  final Uri? uri;
  AndroidOptions? options;

  @override
  Future<Uri?> pickDirectory({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    options = androidOptions;
    return uri;
  }
}

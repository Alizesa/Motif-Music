import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/taglib_metadata_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('motif/library_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const uri = 'content://provider/tree/root/document/root%2F歌曲.flac';
  const file = LocalAudioFile(
    id: 1,
    location: FileLocation(
      platform: LibraryPlatform.android,
      key: 'provider|root/歌曲.flac',
      locator: uri,
    ),
    fileName: '歌曲.flac',
    sizeBytes: 42,
    modifiedMs: 100,
    metadata: TrackMetadata(state: MetadataState.pending),
    revision: 1,
    normalizationVersion: 1,
    isPresent: true,
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('SAF reader preserves exact URI and releases detached descriptor after success', () async {
    final calls = <String>[];
    final closed = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect((call.arguments as Map)['uri'], uri);
      return {
        'sizeBytes': 42,
        'modifiedMs': 100,
        if (call.method == 'openMetadataFile') 'fd': 77,
      };
    });
    final reader = TagLibMetadataReader(
      closeDescriptor: closed.add,
      readDescriptor: (fd) async {
        expect(fd, 77);
        expect(closed, [-1]);
        return {'title': '歌曲', 'durationMs': 123456};
      },
    );
    expect((await reader.read(file)).title, '歌曲');
    expect(calls, ['openMetadataFile', 'metadataFileState']);
    expect(closed, [-1, 77]);
  });

  for (final failure in [
    'parse',
    'changed-before',
    'changed-after',
    'unknown-after',
    'provider-after',
  ]) {
    test('SAF descriptor closes after $failure failure', () async {
      final closed = <int>[];
      var parsed = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openMetadataFile') {
          return {
            'fd': 77,
            'sizeBytes': failure == 'changed-before' ? 43 : 42,
            'modifiedMs': 100,
          };
        }
        if (failure == 'provider-after') {
          throw PlatformException(code: 'provider_failed');
        }
        if (failure == 'unknown-after') return <String, Object?>{};
        return {
          'sizeBytes': failure == 'changed-after' ? 43 : 42,
          'modifiedMs': 100,
        };
      });
      final reader = TagLibMetadataReader(
        closeDescriptor: closed.add,
        readDescriptor: (_) async {
          parsed = true;
          if (failure == 'parse') throw StateError('bad audio');
          return {'title': 'discarded'};
        },
      );
      await expectLater(reader.read(file), throwsA(anything));
      expect(closed, [-1, 77]);
      expect(parsed, failure != 'changed-before');
    });
  }
}

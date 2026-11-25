import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/downloads/platform_download_destination.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows commit never overwrites a same-named file and keeps exact bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'motif-download-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final old = File('${root.path}/歌曲.mp3');
      await old.writeAsString('existing content');
      final writer = await FileDownloadWriter.create(root);
      await writer.write(Uint8List.fromList([1, 2, 3, 4]));
      final receipt = await writer.finish('歌曲', 'mp3');
      expect(receipt.name, '歌曲 (1).mp3');
      expect(await File(receipt.location).readAsBytes(), [1, 2, 3, 4]);
      expect(await old.readAsString(), 'existing content');
      await writer.abort();
      expect(await File(receipt.location).exists(), isTrue);
      expect(root.listSync().whereType<File>().length, 2);
    },
    skip: !Platform.isWindows,
  );

  test('Windows cancel deletes only the owned temporary file', () async {
    final root = await Directory.systemTemp.createTemp('motif-download-abort-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/existing.part').writeAsString('keep');
    final writer = await FileDownloadWriter.create(root);
    await writer.write(Uint8List.fromList([1, 2]));
    await writer.abort();
    await writer.abort();
    expect(root.listSync().map((file) => file.uri.pathSegments.last), [
      'existing.part',
    ]);
  }, skip: !Platform.isWindows);

  test(
    'Android channel writes bounded chunks and returns the provider filename',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlatformDownloadDestination.channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'pickDirectory' => {
            'uri': 'content://documents/tree/music',
            'label': 'Music',
          },
          'begin' => 'owned-id',
          'finish' => {
            'name': 'Song (1).flac',
            'location': 'content://documents/document/new-song',
          },
          _ => null,
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          PlatformDownloadDestination.channel,
          null,
        ),
      );
      const destination = SafDownloadDestination();
      final directory = await destination.chooseDirectory();
      final writer = await destination.create(directory!);
      await writer.write(Uint8List.fromList([4, 5, 6]));
      final receipt = await writer.finish('Song', 'flac');
      expect(receipt.name, 'Song (1).flac');
      expect(calls.map((call) => call.method), [
        'pickDirectory',
        'begin',
        'write',
        'finish',
      ]);
      expect((calls[2].arguments as Map)['bytes'], [4, 5, 6]);
      expect((calls[3].arguments as Map)['id'], 'owned-id');
      expect((calls[3].arguments as Map)['extension'], 'flac');
    },
  );

  test('Android cancelled directory picker creates no document', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      PlatformDownloadDestination.channel,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        PlatformDownloadDestination.channel,
        null,
      ),
    );
    expect(await const SafDownloadDestination().chooseDirectory(), isNull);
  });
}

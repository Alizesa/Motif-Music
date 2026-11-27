import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/downloads/platform_download_destination.dart';
import 'package:motif/downloads/download_destination.dart';
import 'package:motif/downloads/download_storage_error.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/lx_download.dart';

import '../support/lx_encoded_fixture.dart';

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

  test(
    'Windows commits from the directory URI returned by the picker',
    () async {
      final root = await Directory.systemTemp.createTemp('motif-folder-');
      addTearDown(() => root.delete(recursive: true));
      final folder = await Directory('${root.path}/下载 #100%').create();
      final uri = Uri.directory(folder.path, windows: true);
      expect(uri.path.endsWith('/'), isTrue);
      final writer = await const PlatformDownloadDestination().create(
        DownloadDirectory(uri, folder.path),
      );
      try {
        final audio = flacFixture();
        final transport = EncodedFixtureTransport(audio);
        final extension = await downloadLxAudio(
          transport,
          PcmCancellation(),
          writer.write,
          (length) => expect(length, audio.length),
        );
        final receipt = await writer.finish('歌曲 #50%', extension);
        expect(receipt.name, '歌曲 #50%.flac');
        expect(await File(receipt.location).readAsBytes(), audio);
        expect(transport.opens, [(0, null)]);
        expect(
          await FileSystemEntity.identical(
            File(receipt.location).parent.path,
            folder.path,
          ),
          isTrue,
        );
      } finally {
        await writer.abort();
      }
    },
    skip: !Platform.isWindows,
  );

  test('Windows reports known OS errors without leaking paths or treating unknown errors as access denied', () {
    for (final (code, problem) in [
      (5, DownloadStorageProblem.permission),
      (112, DownloadStorageProblem.noSpace),
      (32, DownloadStorageProblem.busy),
      (3, DownloadStorageProblem.unavailable),
      (206, DownloadStorageProblem.name),
      (9999, DownloadStorageProblem.io),
    ]) {
      final failure = DownloadStorageException.from(
        FileSystemException(
          'private message',
          'private folder',
          OSError('private detail', code),
        ),
      );
      expect(failure.problem, problem);
      expect(failure.osCode, code);
      expect(failure.message('保存最终文件'), isNot(contains('private')));
    }
  }, skip: !Platform.isWindows);

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

  test('Android restores only the remembered tree without reopening picker or creating documents', () async {
    final uri = Uri.parse('content://provider/tree/primary%3AMusic%2FLibrary');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    var revoked = false, wrongTree = false;
    messenger.setMockMethodCallHandler(PlatformDownloadDestination.channel, (
      call,
    ) async {
      calls++;
      expect(call.method, 'restoreDirectory');
      expect(call.arguments, {'directory': uri.toString()});
      if (revoked) throw PlatformException(code: 'download_permission');
      return {
        'uri': wrongTree ? 'content://provider/tree/another' : uri.toString(),
        'label': 'Music',
      };
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        PlatformDownloadDestination.channel,
        null,
      ),
    );
    const dest = SafDownloadDestination();
    expect((await dest.restoreDirectory(uri)).label, 'Music');
    wrongTree = true;
    await expectLater(dest.restoreDirectory(uri), throwsA(isA<Exception>()));
    revoked = true;
    await expectLater(
      dest.restoreDirectory(uri),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'download_permission',
        ),
      ),
    );
    await expectLater(
      dest.restoreDirectory(Uri.file('/wrong-platform')),
      throwsA(isA<Exception>()),
    );
    expect(calls, 3);
  });

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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/audio_file_extensions.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';
import 'package:motif/library/platform/windows_library_source.dart';

void main() {
  test('Windows root enumeration failure aborts the traversal', () async {
    final missing = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}motif-missing-root',
    );
    final root = FileLocation(
      platform: LibraryPlatform.windows,
      key: 'missing-root',
      locator: Uri.directory(missing.path).toString(),
    );
    await expectLater(
      const WindowsLibrarySource()
          .scanBatches(root, cancellation: LibraryScanCancellation())
          .toList(),
      throwsA(
        isA<LibraryTraversalException>().having(
          (error) => error.rootAccessRevoked,
          'rootAccessRevoked',
          isTrue,
        ),
      ),
    );
  });

  test('Windows keys normalize Unicode case before URI encoding', () async {
    final temp = await Directory.systemTemp.createTemp('motif-unicode-');
    try {
      const name = 'ÄRGER-歌曲.MP3';
      final file = File('${temp.path}${Platform.pathSeparator}$name');
      await file.create();
      final batches = await const WindowsLibrarySource()
          .scanBatches(
            FileLocation(
              platform: LibraryPlatform.windows,
              key: 'unicode-root',
              locator: Uri.directory(temp.path).toString(),
            ),
            cancellation: LibraryScanCancellation(),
          )
          .toList();
      final found = batches.single.single;
      expect(found.fileName, name);
      expect(
        found.location.key,
        Uri.file(
          file.path.toLowerCase(),
          windows: Platform.isWindows,
        ).normalizePath().toString(),
      );
      expect(Uri.parse(found.location.locator).pathSegments.last, name);
      expect(
        Uri.parse(found.location.key).pathSegments.last,
        name.toLowerCase(),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });
  test('audio extension allowlist is case-insensitive and conservative', () {
    for (final name in [
      'song.M4A',
      'song.ogg',
      'song.OGA',
      'song.Mp3',
      'song.flac',
      'song.WAV',
      'song.aac',
      'song.ALAC',
      'song.ape',
      'song.OPUS',
      'song.wma',
    ]) {
      expect(isSupportedAudioFileName(name), isTrue, reason: name);
    }
    for (final name in ['cover.jpg', 'readme.txt', 'track', 'track.']) {
      expect(isSupportedAudioFileName(name), isFalse, reason: name);
    }
  });

  test(
    'Windows traversal filters recursively and emits bounded batches',
    () async {
      final temp = await Directory.systemTemp.createTemp('motif-library-walk-');
      try {
        for (var i = 0; i < 201; i++) {
          await File('${temp.path}${Platform.pathSeparator}track-$i.MP3')
              .create(recursive: true);
        }
        final nested = Directory('${temp.path}${Platform.pathSeparator}nested');
        await nested.create();
        await File('${nested.path}${Platform.pathSeparator}bonus.OgG').create();
        await File('${nested.path}${Platform.pathSeparator}cover.jpg').create();

        final root = FileLocation(
          platform: LibraryPlatform.windows,
          key: 'test-root',
          locator: Uri.directory(temp.path).toString(),
        );
        final batches = await const WindowsLibrarySource()
            .scanBatches(root, cancellation: LibraryScanCancellation())
            .toList();
        final files = batches.expand((batch) => batch).toList();

        expect(batches.map((batch) => batch.length), [200, 2]);
        expect(files, hasLength(202));
        expect(files.map((file) => file.fileName), contains('bonus.OgG'));
        expect(
          files.map((file) => file.fileName),
          isNot(contains('cover.jpg')),
        );
        expect(
          files.every(
            (file) =>
                file.location.platform == LibraryPlatform.windows &&
                file.location.key ==
                    Uri.file(
                      Uri.parse(file.location.locator)
                          .toFilePath(windows: Platform.isWindows)
                          .toLowerCase(),
                      windows: Platform.isWindows,
                    ).normalizePath().toString() &&
                Uri.parse(file.location.locator).scheme == 'file',
          ),
          isTrue,
        );
        expect(files.every((file) => file.metadata == null), isTrue);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}

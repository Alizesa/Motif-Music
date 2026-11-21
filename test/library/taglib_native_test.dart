@Tags(['taglib-native'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_metadata_service.dart';
import 'package:motif/library/application/library_scan_service.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';
import 'package:motif/library/platform/taglib_metadata_reader.dart';
import 'package:motif/library/platform/windows_library_source.dart';
import 'package:motif_taglib/motif_taglib.dart';

import '../support/library_fixtures.dart';
import '../support/wav_fixture.dart';

void main() {
  for (final tagged in [false, true]) {
    test(
      'native readonly WAV extraction (tagged=$tagged) handles Unicode paths and releases handles',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'motif-taglib-',
        );
        try {
          final file = File(
            '${directory.path}${Platform.pathSeparator}中文 音乐.wav',
          );
          final bytes = wavFixture(tagged: tagged);
          await file.writeAsBytes(bytes);
          for (var i = 0; i < 3; i++) {
            final path = file.path;
            final tags = await Isolate.run(() => readTagLib(path: path));
            expect(tags['title'], tagged ? 'A "song"' : '');
            expect(tags['artist'], tagged ? 'Artist' : '');
            expect(tags['album'], tagged ? 'Album' : '');
            expect(tags['durationMs'], 1000);
            expect(tags['bitrateKbps'], 128);
            expect(tags['sampleRateHz'], 8000);
            expect(tags['channels'], 1);
          }
          expect(await file.readAsBytes(), bytes);
          await file.rename('${file.path}.renamed');
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test('native invalid file fails without retaining its read handle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'motif-taglib-invalid-',
    );
    try {
      final file = File('${directory.path}${Platform.pathSeparator}bad.flac');
      await file.writeAsString('not audio');
      final path = file.path;
      await expectLater(
        Isolate.run(() => readTagLib(path: path)),
        throwsFormatException,
      );
      await file.delete();
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test(
    'native scan and parse persist tags and keep a failed file indexed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'motif-taglib-scan-',
      );
      addTearDown(() => deleteTestDirectory(directory));
      final database = LibraryDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final good = File.fromUri(directory.uri.resolve('tagged.wav'));
      final bad = File.fromUri(directory.uri.resolve('bad.flac'));
      await good.writeAsBytes(wavFixture(tagged: true));
      await bad.writeAsString('not audio');
      final repository = LibraryRepository(database);
      final root = await repository.addDirectory(
        location: FileLocation(
          platform: LibraryPlatform.windows,
          key: 'taglib-scan-test',
          locator: directory.uri.toString(),
        ),
        displayName: 'Native scan fixture',
      );
      final scan = LibraryScanService(repository, const WindowsLibrarySource());
      expect(await scan.scanDirectory(root.id), 2);
      final before = await repository.filesPage();
      expect(before, hasLength(2));
      expect(
        before.map((file) => file.metadata.state),
        everyElement(MetadataState.pending),
      );

      final progress = await LibraryMetadataService(
        repository,
        const TagLibMetadataReader(),
      ).run(cancellation: LibraryScanCancellation());
      expect(progress.processed, 2);
      expect(progress.failed, 1);
      expect(progress.discarded, 0);
      final after = await repository.filesPage();
      expect(after.map((file) => file.id), before.map((file) => file.id));
      final track = after.singleWhere((file) => file.fileName == 'tagged.wav');
      expect(track.metadata.state, MetadataState.ready);
      expect(track.metadata.title, 'A "song"');
      expect(track.metadata.artist, 'Artist');
      expect(track.metadata.album, 'Album');
      expect(track.metadata.durationMs, 1000);
      expect(track.metadata.bitrateKbps, 128);
      expect(track.metadata.sampleRateHz, 8000);
      expect(track.metadata.channels, 1);
      expect(track.metadata.isLossless, isNull);
      final failed = after.singleWhere((file) => file.fileName == 'bad.flac');
      expect(failed.metadata.state, MetadataState.failed);
      expect(await repository.fileById(failed.id), isNotNull);
      expect((await repository.directories()).single.lastScanState, 'complete');
      await good.rename('${good.path}.renamed');
      await bad.delete();
    },
  );
  test(
    'native FD extraction borrows readonly handles and rejects writable ones',
    () async {
      final libc = DynamicLibrary.open('libc.so.6');
      final open = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('open');
      final close = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      final seek = libc
          .lookupFunction<
            Int64 Function(Int32, Int64, Int32),
            int Function(int, int, int)
          >('lseek');
      final directory = await Directory.systemTemp.createTemp(
        'motif-taglib-fd-',
      );
      try {
        final file = File('${directory.path}/borrowed.wav');
        await file.writeAsBytes(wavFixture(tagged: true));
        final path = file.path.toNativeUtf8();
        try {
          for (final access in [0, 2]) {
            // POSIX O_RDONLY, O_RDWR
            final fd = open(path, access);
            expect(fd, greaterThanOrEqualTo(0));
            try {
              if (access == 0) {
                for (var i = 0; i < 3; i++) {
                  final tags = await Isolate.run(
                    () => readTagLib(descriptor: fd),
                  );
                  expect(tags['title'], 'A "song"');
                  expect(tags['durationMs'], 1000);
                  expect(seek(fd, 0, 0), 0); // Borrowed FD is still valid.
                }
              } else {
                await expectLater(
                  Isolate.run(() => readTagLib(descriptor: fd)),
                  throwsFormatException,
                );
                expect(seek(fd, 0, 0), 0);
              }
            } finally {
              close(fd);
            }
          }
        } finally {
          malloc.free(path);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isLinux,
  );
}

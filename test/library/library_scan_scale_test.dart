import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_scan_service.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';

void main() {
  test(
    '100k-file scan pipeline stays bounded through an incremental rescan',
    () async {
      final database = LibraryDatabase(NativeDatabase.memory());
      try {
        final repository = LibraryRepository(database);
        final root = await repository.addDirectory(
          location: const FileLocation(
            platform: LibraryPlatform.windows,
            key: 'scan-scale',
            locator: 'file:///scan-scale',
          ),
          displayName: 'Synthetic scan',
        );
        final source = _ScaleSource();
        final service = LibraryScanService(repository, source);
        var progress = 0;
        expect(
          await service.scanDirectory(
            root.id,
            onProgress: (count) {
              expect(count, greaterThan(progress));
              progress = count;
              expect(source.emittedBatches, (count + 199) ~/ 200);
            },
          ),
          100000,
        );
        expect(progress, 100000);
        expect(source.emittedBatches, 500);
        expect(source.largestBatch, 200);
        final stableBefore = (await repository.filesPage(
          afterId: 1,
          limit: 1,
        )).single;
        final changedBefore = (await repository.filesPage(
          afterId: 99999,
          limit: 1,
        )).single;
        expect(stableBefore.metadata.state, MetadataState.pending);

        source.rescan = true;
        source.emittedBatches = 0;
        expect(await service.scanDirectory(root.id), 99999);
        expect(source.emittedBatches, 500);
        final stableAfter = (await repository.filesPage(
          afterId: 1,
          limit: 1,
        )).single;
        final changedAfter = (await repository.filesPage(
          afterId: 99999,
          limit: 1,
        )).single;
        expect(stableAfter.id, stableBefore.id);
        expect(stableAfter.revision, stableBefore.revision);
        expect(changedAfter.id, changedBefore.id);
        expect(changedAfter.revision, greaterThan(changedBefore.revision));
        expect(changedAfter.metadata.state, MetadataState.pending);
        final counts = await database
            .customSelect(
              'SELECT COUNT(*) AS total, SUM(is_present) AS present FROM local_tracks',
            )
            .getSingle();
        expect(counts.read<int>('total'), 100000);
        expect(counts.read<int>('present'), 99999);
        final completed = (await repository.directories()).single;
        expect(completed.scanGeneration, 2);
        expect(completed.activeGeneration, isNull);
        expect(completed.lastScanState, 'complete');
        expect(
          await database.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await database.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _ScaleSource implements LibraryPlatformSource {
  var rescan = false;
  var emittedBatches = 0;
  var largestBatch = 0;

  @override
  LibraryPlatform get platform => LibraryPlatform.windows;

  @override
  Future<PickedLibraryDirectory?> pickDirectory() async => null;

  @override
  Future<void> releaseDirectory(FileLocation root) async {}

  @override
  Stream<List<ObservedAudioFile>> scanBatches(
    FileLocation root, {
    required LibraryScanCancellation cancellation,
  }) async* {
    var batch = <ObservedAudioFile>[];
    for (var i = rescan ? 1 : 0; i < 100000; i++) {
      cancellation.throwIfCancelled();
      batch.add(
        ObservedAudioFile(
          location: FileLocation(
            platform: platform,
            key: 'scale-file-$i',
            locator: 'file:///scan-scale/$i.opus',
          ),
          fileName: '$i.opus',
          sizeBytes: 42,
          modifiedMs: rescan && i == 99999 ? 200 : 100,
        ),
      );
      if (batch.length == libraryScanBatchLimit) {
        emittedBatches++;
        largestBatch = batch.length;
        yield batch;
        batch = [];
      }
    }
    if (batch.isNotEmpty) {
      emittedBatches++;
      yield batch;
    }
  }
}

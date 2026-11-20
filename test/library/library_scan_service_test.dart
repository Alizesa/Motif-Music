import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_scan_service.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';

void main() {
  late LibraryDatabase database;
  late LibraryRepository repository;
  late LibraryDirectory root;

  setUp(() async {
    database = LibraryDatabase(NativeDatabase.memory());
    repository = LibraryRepository(database);
    root = await repository.addDirectory(
      location: const FileLocation(
        platform: LibraryPlatform.windows,
        key: 'root-key',
        locator: 'file:///music',
      ),
      displayName: 'Music',
    );
  });

  tearDown(() => database.close());

  test(
    'successful traversal persists pending metadata and completes root',
    () async {
      final source = _FakeSource([
        [
          _file('one', 'file:///music/one.flac'),
          _file('two', 'file:///music/two.m4a'),
        ],
      ]);
      final service = LibraryScanService(repository, source);

      final count = await service.scanDirectory(root.id);

      expect(count, 2);
      final files = await repository.filesPage(limit: 10);
      expect(files, hasLength(2));
      expect(
        files.every((file) => file.metadata.state == MetadataState.pending),
        isTrue,
      );
      expect((await repository.directories()).single.lastScanState, 'complete');
      expect((await repository.directories()).single.isAccessible, isTrue);
    },
  );

  test(
    'failed partial traversal does not retire unseen existing members',
    () async {
      final initial = await repository.beginScan(root.id);
      await repository.writeScanBatch(initial, [
        _file('existing', 'file:///music/existing.flac'),
      ]);
      await repository.completeScan(initial);

      final source = _FakeSource(
        [
          [_file('new', 'file:///music/new.flac')],
        ],
        failAfterBatches: const LibraryTraversalException(
          'subdirectory failed',
        ),
      );
      final service = LibraryScanService(repository, source);

      await expectLater(
        service.scanDirectory(root.id),
        throwsA(isA<LibraryTraversalException>()),
      );

      final files = await repository.filesPage(limit: 10);
      expect(
        files.map((file) => file.fileName),
        containsAll(['existing.flac', 'new.flac']),
      );
      expect(files.every((file) => file.isPresent), isTrue);
      expect((await repository.directories()).single.lastScanState, 'failed');
    },
  );

  test(
    'cancellation records interrupted and preserves unseen members',
    () async {
      final initial = await repository.beginScan(root.id);
      await repository.writeScanBatch(initial, [
        _file('existing', 'file:///music/existing.flac'),
      ]);
      await repository.completeScan(initial);

      final cancellation = LibraryScanCancellation();
      final service = LibraryScanService(
        repository,
        _FakeSource([
          [_file('new', 'file:///music/new.flac')],
          [_file('later', 'file:///music/later.flac')],
        ]),
      );
      await expectLater(
        service.scanDirectory(
          root.id,
          cancellation: cancellation,
          onProgress: (_) => cancellation.cancel(),
        ),
        throwsA(isA<LibraryScanCancelledException>()),
      );

      final files = await repository.filesPage(limit: 10);
      expect(
        files.map((file) => file.fileName),
        containsAll(['existing.flac', 'new.flac']),
      );
      expect(files.map((file) => file.fileName), isNot(contains('later.flac')));
      expect(files.every((file) => file.isPresent), isTrue);
      expect(
        (await repository.directories()).single.lastScanState,
        'interrupted',
      );
    },
  );

  test(
    'pre-cancelled scans leave the generation and root state unchanged',
    () async {
      final cancellation = LibraryScanCancellation()..cancel();
      final service = LibraryScanService(repository, _FakeSource(const []));
      await expectLater(
        service.scanDirectory(root.id, cancellation: cancellation),
        throwsA(isA<LibraryScanCancelledException>()),
      );
      final unchanged = (await repository.directories()).single;
      expect(unchanged.scanGeneration, root.scanGeneration);
      expect(unchanged.lastScanState, root.lastScanState);
    },
  );

  for (final size in [0, 201]) {
    test(
      'invalid batch size $size fails without retiring existing members',
      () async {
        final initial = await repository.beginScan(root.id);
        await repository.writeScanBatch(initial, [
          _file('existing', 'file:///music/existing.flac'),
        ]);
        await repository.completeScan(initial);
        final service = LibraryScanService(
          repository,
          _FakeSource([
            List.generate(
              size,
              (i) => _file('new-$i', 'file:///music/new-$i.flac'),
            ),
          ]),
        );
        await expectLater(service.scanDirectory(root.id), throwsStateError);
        expect((await repository.filesPage()).single.fileName, 'existing.flac');
        expect((await repository.directories()).single.lastScanState, 'failed');
      },
    );
  }

  test('a fully traversed empty root can retire missing files', () async {
    final initial = await repository.beginScan(root.id);
    await repository.writeScanBatch(initial, [
      _file('existing', 'file:///music/existing.flac'),
    ]);
    await repository.completeScan(initial);
    final service = LibraryScanService(repository, _FakeSource(const []));
    expect(await service.scanDirectory(root.id), 0);
    expect(await repository.filesPage(), isEmpty);
    expect((await repository.directories()).single.lastScanState, 'complete');
  });
  test('revoked root access marks the directory inaccessible', () async {
    final service = LibraryScanService(
      repository,
      _FakeSource(
        const [],
        failAfterBatches: const LibraryTraversalException(
          'permission revoked',
          rootAccessRevoked: true,
        ),
      ),
    );

    await expectLater(
      service.scanDirectory(root.id),
      throwsA(isA<LibraryTraversalException>()),
    );

    final directory = (await repository.directories()).single;
    expect(directory.isAccessible, isFalse);
    expect(directory.lastScanState, 'failed');
  });
}

ObservedAudioFile _file(String key, String locator) => ObservedAudioFile(
  location: FileLocation(
    platform: LibraryPlatform.windows,
    key: key,
    locator: locator,
  ),
  fileName: '$key.flac',
  sizeBytes: 42,
  modifiedMs: 100,
);

class _FakeSource implements LibraryPlatformSource {
  _FakeSource(this.batches, {this.failAfterBatches});

  final List<List<ObservedAudioFile>> batches;
  final LibraryTraversalException? failAfterBatches;

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
    for (final batch in batches) {
      cancellation.throwIfCancelled();
      yield batch;
    }
    if (failAfterBatches case final error?) throw error;
  }
}

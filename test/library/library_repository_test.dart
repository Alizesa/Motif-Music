import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/track_normalization.dart';

FileLocation location(
  String key, {
  LibraryPlatform platform = LibraryPlatform.windows,
}) => FileLocation(
  platform: platform,
  key: key,
  locator: 'file:///music/$key.flac',
);

ObservedAudioFile audioFile(
  String key, {
  String title = 'Song',
  String artist = 'Artist',
  int? durationMs = 180000,
  int? modifiedMs = 1000,
  int? sizeBytes = 5000,
  bool withMetadata = true,
}) => ObservedAudioFile(
  location: location(key),
  fileName: '$key.flac',
  sizeBytes: sizeBytes,
  modifiedMs: modifiedMs,
  metadata: withMetadata
      ? TrackMetadata(
          title: title,
          artist: artist,
          album: 'Album',
          durationMs: durationMs,
          container: 'flac',
          codec: 'flac',
        )
      : null,
);

void main() {
  // Tests use isolated executors; Drift's global counter cannot distinguish them.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late LibraryDatabase database;
  late LibraryRepository repository;

  setUp(() {
    database = LibraryDatabase(NativeDatabase.memory());
    repository = LibraryRepository(database);
  });
  tearDown(() => database.close());

  Future<LibraryDirectory> root([String key = 'root']) =>
      repository.addDirectory(location: location(key), displayName: key);

  Future<void> scan(LibraryDirectory dir, List<ObservedAudioFile> files) async {
    final session = await repository.beginScan(dir.id);
    await repository.writeScanBatch(session, files);
    await repository.completeScan(session);
  }

  Future<void> confirm(
    LocalAudioFile file, {
    String source = 'qq',
    String id = 'song-id',
  }) => repository.confirmSourceMatch(
    source: source,
    sourceTrackId: id,
    fileId: file.id,
    expectedRevision: file.revision,
    decision: MatchDecision.manual,
    matcherVersion: 1,
  );

  test(
    'stable file IDs and revisions survive unchanged incremental scans',
    () async {
      final dir = await root();
      await scan(dir, [audioFile('a')]);
      final original = (await repository.filesPage()).single;
      await scan(dir, [audioFile('a', withMetadata: false)]);
      final unchanged = (await repository.filesPage()).single;
      expect(unchanged.id, original.id);
      expect(unchanged.revision, original.revision);
      expect(unchanged.metadata.title, 'Song');
      await scan(dir, [audioFile('a')]);
      expect((await repository.filesPage()).single.revision, original.revision);
    },
  );

  test(
    'overlapping roots share a file; losing one root preserves it',
    () async {
      final first = await root('parent');
      final second = await root('child');
      await scan(first, [audioFile('same')]);
      await scan(second, [audioFile('same')]);
      final original = (await repository.filesPage()).single;
      await scan(first, []);
      expect((await repository.filesPage()).single.id, original.id);
      await repository.removeDirectory(second.id);
      expect(await repository.filesPage(), isEmpty);
      await scan(first, [audioFile('same')]);
      expect((await repository.filesPage()).single.id, original.id);
    },
  );

  test('interrupted or failed scan does not retire unseen files', () async {
    final dir = await root();
    await scan(dir, [audioFile('a'), audioFile('b')]);
    final interrupted = await repository.beginScan(dir.id);
    await repository.writeScanBatch(interrupted, [audioFile('a')]);
    await repository.recoverInterruptedScans();
    expect((await repository.filesPage()).length, 2);
    expect(
      (await repository.directories()).single.lastScanState,
      'interrupted',
    );
    final retry = await repository.beginScan(dir.id);
    await expectLater(repository.completeScan(interrupted), throwsStateError);
    await expectLater(
      repository.writeScanBatch(interrupted, [audioFile('wrong')]),
      throwsStateError,
    );
    await repository.failScan(retry);
    expect((await repository.filesPage()).length, 2);
    await scan(dir, [audioFile('a')]);
    expect((await repository.filesPage()).single.location.key, 'a');
  });

  test(
    'overlapping SAF grants retain an independently usable URI per root',
    () async {
      FileLocation saf(String key, String uri) => FileLocation(
        platform: LibraryPlatform.android,
        key: key,
        locator: uri,
      );
      final first = await repository.addDirectory(
        location: saf('root-1', 'content://provider/tree/one'),
        displayName: 'one',
      );
      final second = await repository.addDirectory(
        location: saf('root-2', 'content://provider/tree/two'),
        displayName: 'two',
      );
      Future<void> add(LibraryDirectory dir, String uri) async {
        final session = await repository.beginScan(dir.id);
        await repository.writeScanBatch(session, [
          ObservedAudioFile(
            location: saf('provider:document/audio', uri),
            fileName: 'song.ogg',
            sizeBytes: 1000,
            modifiedMs: 1,
            metadata: const TrackMetadata(title: 'Song', durationMs: 180000),
          ),
        ]);
        await repository.completeScan(session);
      }

      await add(first, 'content://provider/tree/one/document/audio');
      await add(second, 'content://provider/tree/two/document/audio');
      final original = (await repository.filesPage()).single;
      expect(original.location.locator, contains('/tree/one/'));
      await confirm(original);
      final failed = await repository.beginScan(first.id);
      await repository.failScan(failed, accessRevoked: true);
      final playable = await repository.confirmedMatch(
        source: 'qq',
        sourceTrackId: 'song-id',
      );
      expect(playable?.id, original.id);
      expect(playable?.location.locator, contains('/tree/two/'));
    },
  );
  test(
    'a directory has only one active scan and stale sessions cannot finish it',
    () async {
      final dir = await root();
      final first = await repository.beginScan(dir.id);
      await expectLater(repository.beginScan(dir.id), throwsStateError);
      await repository.failScan(first);
      final second = await repository.beginScan(dir.id);
      expect(second.generation, greaterThan(first.generation));
      await expectLater(repository.completeScan(first), throwsStateError);
      await repository.completeScan(second);
    },
  );

  test(
    'source namespace isolates identical IDs and confirmed lookup is local',
    () async {
      final dir = await root();
      await scan(dir, [audioFile('a'), audioFile('b')]);
      final files = await repository.filesPage();
      await confirm(files[0], source: 'qq');
      await confirm(files[1], source: 'other');
      expect(
        (await repository.confirmedMatch(
          source: 'qq',
          sourceTrackId: 'song-id',
        ))?.id,
        files[0].id,
      );
      expect(
        (await repository.confirmedMatch(
          source: 'other',
          sourceTrackId: 'song-id',
        ))?.id,
        files[1].id,
      );
      expect(
        await repository.confirmedMatch(source: 'QQ', sourceTrackId: 'song-id'),
        isNull,
      );
    },
  );

  test(
    'stat changes clear stale tags and invalidate a confirmed association',
    () async {
      final dir = await root();
      await scan(dir, [audioFile('a')]);
      final original = (await repository.filesPage()).single;
      await confirm(original);
      await scan(dir, [audioFile('a', modifiedMs: 2000, withMetadata: false)]);
      final changed = (await repository.filesPage()).single;
      expect(changed.id, original.id);
      expect(changed.revision, greaterThan(original.revision));
      expect(changed.metadata.title, isEmpty);
      expect(changed.metadata.state, MetadataState.pending);
      expect(
        await repository.confirmedMatch(source: 'qq', sourceTrackId: 'song-id'),
        isNull,
      );
      await expectLater(confirm(original), throwsStateError);
      expect(
        (await repository.matchCandidates(
          title: 'Song',
          durationMs: 180000,
          durationToleranceMs: 2000,
        )).timed,
        isEmpty,
      );
    },
  );

  test(
    'changed tags with identical stats also invalidate the old association',
    () async {
      final dir = await root();
      await scan(dir, [audioFile('a')]);
      final original = (await repository.filesPage()).single;
      await confirm(original);
      await scan(dir, [audioFile('a', title: 'Song (Live)')]);
      expect(
        (await repository.filesPage()).single.revision,
        greaterThan(original.revision),
      );
      expect(
        await repository.confirmedMatch(source: 'qq', sourceTrackId: 'song-id'),
        isNull,
      );
    },
  );

  test(
    'revoked access hides matches without deleting metadata or the link',
    () async {
      final dir = await root();
      await scan(dir, [audioFile('a')]);
      final file = (await repository.filesPage()).single;
      await confirm(file);
      final failed = await repository.beginScan(dir.id);
      await repository.failScan(failed, accessRevoked: true);
      expect(await repository.filesPage(), isEmpty);
      expect(
        await repository.confirmedMatch(source: 'qq', sourceTrackId: 'song-id'),
        isNull,
      );
      await repository.addDirectory(
        location: dir.location,
        displayName: 'reauthorized',
      );
      expect((await repository.filesPage()).single.id, file.id);
      expect(
        await repository.confirmedMatch(source: 'qq', sourceTrackId: 'song-id'),
        isNotNull,
      );
    },
  );

  test(
    'missing files retain their IDs but are absent from matches and browsing',
    () async {
      final dir = await root();
      await scan(dir, [audioFile('a')]);
      final original = (await repository.filesPage()).single;
      await confirm(original);
      await scan(dir, []);
      expect(await repository.filesPage(), isEmpty);
      expect(
        await repository.confirmedMatch(source: 'qq', sourceTrackId: 'song-id'),
        isNull,
      );
      final states = await repository.scanStates(LibraryPlatform.windows, [
        'a',
      ]);
      expect(
        states['a']!.needsMetadata(sizeBytes: 5000, modifiedMs: 1000),
        isTrue,
      );
      await scan(dir, [audioFile('a')]);
      expect((await repository.filesPage()).single.id, original.id);
    },
  );

  test(
    'candidate retrieval separates timing, versions, unknowns and truncation',
    () async {
      final dir = await root();
      await scan(dir, [
        audioFile('a'),
        audioFile('b', durationMs: 180500),
        audioFile('c', durationMs: 210000),
        audioFile('d', durationMs: null),
        audioFile('e', title: 'Song (Live)'),
        audioFile('f', withMetadata: false),
      ]);
      final result = await repository.matchCandidates(
        title: ' ＳＯＮＧ ',
        durationMs: 180000,
        durationToleranceMs: 1000,
        limitPerGroup: 1,
      );
      expect(result.timed.length, 1);
      expect(result.unmeasured.single.location.key, 'd');
      expect(result.isTruncated, isTrue);
      final all = await repository.matchCandidates(
        title: 'Song',
        durationMs: 180000,
        durationToleranceMs: 1000,
      );
      expect(all.timed.map((f) => f.location.key), ['a', 'b']);
      expect(all.isTruncated, isFalse);
      final noDuration = await repository.matchCandidates(
        title: 'Song',
        durationToleranceMs: 0,
      );
      expect(noDuration.timed, isEmpty);
      expect(noDuration.unmeasured.length, 4);
      expect(
        (await repository.matchCandidates(
          title: ' ',
          durationToleranceMs: 0,
        )).timed,
        isEmpty,
      );
    },
  );

  test(
    'bounded keyset pagination has no duplicate rows between pages',
    () async {
      final dir = await root();
      await scan(dir, [for (var i = 0; i < 5; i++) audioFile('$i')]);
      final first = await repository.filesPage(limit: 2);
      final second = await repository.filesPage(
        afterId: first.last.id,
        limit: 2,
      );
      final third = await repository.filesPage(
        afterId: second.last.id,
        limit: 2,
      );
      expect(
        [...first, ...second, ...third].map((f) => f.id).toSet().length,
        5,
      );
      expect(third.length, 1);
      expect(await repository.filesPage(afterId: third.last.id), isEmpty);
      await expectLater(repository.filesPage(limit: 201), throwsArgumentError);
      await expectLater(
        repository.matchCandidates(
          title: 'Song',
          durationToleranceMs: 0,
          limitPerGroup: 101,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'batch validation and session checks protect existing records',
    () async {
      final dir = await root();
      final session = await repository.beginScan(dir.id);
      await expectLater(
        repository.writeScanBatch(session, [
          for (var i = 0; i < 201; i++) audioFile('$i'),
        ]),
        throwsArgumentError,
      );
      await expectLater(
        repository.writeScanBatch(session, [audioFile('bad', sizeBytes: -1)]),
        throwsArgumentError,
      );
      await expectLater(
        repository.writeScanBatch(session, [
          ObservedAudioFile(
            location: location('android', platform: LibraryPlatform.android),
            fileName: 'wrong',
          ),
        ]),
        throwsArgumentError,
      );
      expect(await repository.filesPage(), isEmpty);
      await repository.completeScan(session);
    },
  );

  test(
    'metadata reads are conservative when stats or normalizer are unreliable',
    () {
      FileScanState state({
        int version = TrackNormalization.version,
        bool present = true,
      }) => FileScanState(
        key: 'a',
        sizeBytes: 5000,
        modifiedMs: 1000,
        metadataState: MetadataState.ready,
        normalizationVersion: version,
        isPresent: present,
      );
      expect(state().needsMetadata(sizeBytes: 5000, modifiedMs: 1000), isFalse);
      expect(state().needsMetadata(sizeBytes: null, modifiedMs: 1000), isTrue);
      expect(state().needsMetadata(sizeBytes: 5000, modifiedMs: null), isTrue);
      expect(
        state(version: 0).needsMetadata(sizeBytes: 5000, modifiedMs: 1000),
        isTrue,
      );
      expect(
        state(present: false).needsMetadata(sizeBytes: 5000, modifiedMs: 1000),
        isTrue,
      );
    },
  );

  test('foreign key enforcement and bounded SQLite cache configuration are enabled', () async {
    expect(
      (await database.customSelect('PRAGMA foreign_keys').getSingle())
          .data
          .values
          .single,
      1,
    );
    expect(
      (await database.customSelect('PRAGMA cache_size').getSingle())
          .data
          .values
          .single,
      -4096,
    );
    await expectLater(
      database.customStatement('''
      INSERT INTO root_files(root_id, file_id, seen_generation, file_locator) VALUES (999, 999, 1, 'uri')
    '''),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'v2 persists across close/reopen without rebuilding the index',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'motif-library-test-',
      );
      final path = File(
        '${directory.path}${Platform.pathSeparator}library.sqlite',
      );
      var persistent = LibraryDatabase(NativeDatabase(path));
      try {
        var repo = LibraryRepository(persistent);
        final dir = await repo.addDirectory(
          location: location('root'),
          displayName: 'Music',
        );
        final session = await repo.beginScan(dir.id);
        await repo.writeScanBatch(session, [audioFile('persisted')]);
        await repo.completeScan(session);
        final original = (await repo.filesPage()).single;
        await repo.confirmSourceMatch(
          source: 'qq',
          sourceTrackId: 'id',
          fileId: original.id,
          expectedRevision: original.revision,
          decision: MatchDecision.manual,
          matcherVersion: 1,
        );
        await persistent.close();
        persistent = LibraryDatabase(NativeDatabase(path));
        repo = LibraryRepository(persistent);
        expect((await repo.filesPage()).single.id, original.id);
        expect(
          (await repo.confirmedMatch(source: 'qq', sourceTrackId: 'id'))?.id,
          original.id,
        );
        expect(
          (await persistent.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          2,
        );
      } finally {
        await persistent.close();
        // Windows may briefly retain WAL/directory handles after SQLite closes.
        // Retry only cleanup-related sharing/directory-not-empty errors.
        for (var attempt = 0; ; attempt++) {
          try {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
            break;
          } on FileSystemException catch (error) {
            if (!Platform.isWindows ||
                attempt >= 4 ||
                ![32, 145].contains(error.osError?.errorCode)) {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    },
  );
}

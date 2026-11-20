import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/data/library_sql.dart';
import 'package:motif/library/domain/library_models.dart';

import '../support/library_fixtures.dart';

void main() {
  late LibraryDatabase db;
  late LibraryRepository repository;
  late LibraryDirectory root;
  setUp(() async {
    db = LibraryDatabase(NativeDatabase.memory());
    repository = LibraryRepository(db);
    root = await repository.addDirectory(
      location: testDirectory.location,
      displayName: 'music',
    );
  });
  tearDown(() => db.close());

  Future<void> seed(List<ObservedAudioFile> files) async {
    final scan = await repository.beginScan(root.id);
    for (var offset = 0; offset < files.length; offset += 200) {
      await repository.writeScanBatch(
        scan,
        files.skip(offset).take(200).toList(),
      );
    }
    await repository.completeScan(scan);
  }

  Future<List<MetadataCandidate>> candidates({bool retry = false}) async =>
      (await repository.metadataWindow(
        afterId: 0,
        throughId: await repository.metadataUpperBound(),
        includeFailed: retry,
      )).candidates;

  test('independent metadata write normalizes tags and invalidates source revision', () async {
    await seed([testAudio(1)]);
    final before = (await candidates()).single;
    await repository.confirmSourceMatch(
      source: 'test',
      sourceTrackId: 'one',
      fileId: before.file.id,
      expectedRevision: before.file.revision,
      decision: MatchDecision.manual,
      matcherVersion: 1,
    );
    expect(
      await repository.writeMetadata(
        before,
        const TrackMetadata(
          title: ' Ａ Song ',
          artist: ' Artist ',
          album: 'Album',
          durationMs: 120001,
        ),
      ),
      isTrue,
    );
    final file = (await repository.filesPage()).single;
    expect(file.metadata.title, ' Ａ Song ');
    expect(file.metadata.durationMs, 120001);
    expect(file.revision, before.file.revision + 1);
    expect(
      await repository.confirmedMatch(source: 'test', sourceTrackId: 'one'),
      isNull,
    );
    expect(
      (await db.customSelect('SELECT title_key FROM local_tracks').getSingle())
          .read<String>('title_key'),
      'a song',
    );
    expect(
      await repository.writeMetadata(
        before,
        const TrackMetadata(title: 'stale'),
      ),
      isFalse,
    );
  });

  test('missing tags and unknown duration remain empty trusted keys', () async {
    await seed([testAudio(1)]);
    await repository.writeMetadata(
      (await candidates()).single,
      const TrackMetadata(),
    );
    final file = (await repository.filesPage()).single;
    expect(file.metadata.state, MetadataState.ready);
    expect(file.metadata.durationMs, isNull);
    expect(file.metadata.title, isEmpty);
    expect(file.displayTitle, file.fileName);
    final row = await db
        .customSelect('SELECT title_key FROM local_tracks')
        .getSingle();
    expect(row.read<String>('title_key'), isEmpty);
    expect(await candidates(), isEmpty);
  });

  test('failed extraction preserves membership/playback and only explicit retry selects it', () async {
    await seed([testAudio(1)]);
    await repository.writeMetadata(
      (await candidates()).single,
      const TrackMetadata(state: MetadataState.failed),
    );
    expect(await candidates(), isEmpty);
    expect(await candidates(retry: true), hasLength(1));
    final file = (await repository.filesPage()).single;
    expect(await repository.fileById(file.id), isNotNull);
    expect(
      await repository.writeMetadata(
        (await candidates(retry: true)).single,
        const TrackMetadata(title: 'Recovered'),
      ),
      isTrue,
    );
    expect((await repository.filesPage()).single.metadata.title, 'Recovered');
  });

  test('a new scan generation rejects an unchanged-file snapshot', () async {
    await seed([testAudio(1)]);
    final before = (await candidates()).single;
    await seed([testAudio(1)]);
    expect(
      await repository.writeMetadata(before, const TrackMetadata(title: 'old')),
      isFalse,
    );
    expect(
      await repository.writeMetadata(
        (await candidates()).single,
        const TrackMetadata(title: 'new'),
      ),
      isTrue,
    );
  });

  test(
    'changed stats, access revocation and root removal reject old results',
    () async {
      await seed([testAudio(1)]);
      final before = (await candidates()).single;
      final changed = ObservedAudioFile(
        location: testAudio(1).location,
        fileName: 'track-1.flac',
        sizeBytes: 43,
        modifiedMs: 101,
      );
      await seed([changed]);
      expect(
        await repository.writeMetadata(before, const TrackMetadata()),
        isFalse,
      );
      final after = (await candidates()).single;
      final scan = await repository.beginScan(root.id);
      await repository.failScan(scan, accessRevoked: true);
      expect(
        await repository.writeMetadata(after, const TrackMetadata()),
        isFalse,
      );
      expect(await candidates(), isEmpty);
      await repository.removeDirectory(root.id);
      expect(
        await repository.writeMetadata(after, const TrackMetadata()),
        isFalse,
      );
    },
  );

  test('bounded windows advance through ready IDs and exclude new IDs past the job boundary', () async {
    await seed(List.generate(405, (i) => testAudio(i + 1)));
    final upper = await repository.metadataUpperBound();
    var cursor = 0;
    var count = 0;
    while (cursor < upper) {
      final page = await repository.metadataWindow(
        afterId: cursor,
        throughId: upper,
        limit: 37,
      );
      expect(page.candidates.length, lessThanOrEqualTo(37));
      expect(page.afterId, greaterThan(cursor));
      count += page.candidates.length;
      cursor = page.afterId;
    }
    expect(count, 405);
    await seed(List.generate(406, (i) => testAudio(i + 1)));
    expect(
      (await repository.metadataWindow(
        afterId: upper,
        throughId: upper,
      )).candidates,
      isEmpty,
    );
    await expectLater(
      repository.metadataWindow(afterId: 0, throughId: upper, limit: 201),
      throwsArgumentError,
    );
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN ${LibrarySql.metadataWindow}',
          variables: [
            const Variable<int>(0),
            Variable<int>(upper),
            const Variable<int>(37),
          ],
        )
        .get();
    expect(
      plan.map((r) => r.read<String>('detail')).join(' '),
      contains('tracks_present_page'),
    );
  });

  test('reject pending or nonpositive metadata writes', () async {
    await seed([testAudio(1)]);
    final before = (await candidates()).single;
    await expectLater(
      repository.writeMetadata(
        before,
        const TrackMetadata(state: MetadataState.pending),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.writeMetadata(before, const TrackMetadata(durationMs: 0)),
      throwsArgumentError,
    );
  });
  test(
    'resurrected same-stat files clear old tags and require fresh extraction',
    () async {
      await seed([testAudio(1)]);
      final original = (await candidates()).single;
      await repository.writeMetadata(
        original,
        const TrackMetadata(title: 'Old'),
      );
      await seed([]);
      await seed([testAudio(1)]);
      final resurrected = (await candidates()).single;
      expect(resurrected.file.id, original.file.id);
      expect(resurrected.file.metadata.title, isEmpty);
      expect(resurrected.file.revision, greaterThan(original.file.revision));
    },
  );

  test(
    'unknown file stats cause explicit rescans to invalidate ready metadata',
    () async {
      final observed = ObservedAudioFile(
        location: testAudio(1).location,
        fileName: 'track-1.flac',
        sizeBytes: 42,
      );
      await seed([observed]);
      await repository.writeMetadata(
        (await candidates()).single,
        const TrackMetadata(title: 'Old'),
      );
      await seed([observed]);
      final pending = (await candidates()).single.file;
      expect(pending.metadata.state, MetadataState.pending);
      expect(pending.metadata.title, isEmpty);
    },
  );
  test(
    'overlapping members select a usable non-scanning locator for metadata',
    () async {
      await seed([testAudio(1)]);
      final original = testAudio(1);
      final second = await repository.addDirectory(
        location: const FileLocation(
          platform: LibraryPlatform.windows,
          key: 'second-root',
          locator: 'file:///C:/other',
        ),
        displayName: 'second',
      );
      final secondScan = await repository.beginScan(second.id);
      const alternate = 'file:///C:/other/member.flac';
      await repository.writeScanBatch(secondScan, [
        ObservedAudioFile(
          location: FileLocation(
            platform: original.location.platform,
            key: original.location.key,
            locator: alternate,
          ),
          fileName: original.fileName,
          sizeBytes: original.sizeBytes,
          modifiedMs: original.modifiedMs,
        ),
      ]);
      await repository.completeScan(secondScan);
      final scanning = await repository.beginScan(root.id);
      final candidate = (await candidates()).single;
      expect(candidate.rootId, second.id);
      expect(candidate.file.location.locator, alternate);
      expect(
        await repository.writeMetadata(
          candidate,
          const TrackMetadata(title: 'Usable'),
        ),
        isTrue,
      );
      await repository.interruptScan(scanning);
    },
  );
}

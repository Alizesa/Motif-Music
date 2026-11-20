import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/data/library_sql.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/track_normalization.dart';

void main() {
  test(
    '100k records use bounded results and indexed production queries',
    () async {
      final database = LibraryDatabase(NativeDatabase.memory());
      final repository = LibraryRepository(database);
      try {
        final root = await repository.addDirectory(
          location: const FileLocation(
            platform: LibraryPlatform.windows,
            key: 'scale-root',
            locator: 'file:///scale',
          ),
          displayName: 'Scale fixture',
        );
        final session = await repository.beginScan(root.id);
        const count = 100000;
        for (
          var start = 0;
          start < count;
          start += LibraryRepository.maxBatchSize
        ) {
          await repository.writeScanBatch(session, [
            for (var i = start; i < start + LibraryRepository.maxBatchSize; i++)
              ObservedAudioFile(
                location: FileLocation(
                  platform: LibraryPlatform.windows,
                  key: 'file-$i',
                  locator: 'file:///scale/$i.flac',
                ),
                fileName: '$i.flac',
                sizeBytes: 5000,
                modifiedMs: 1000,
                metadata: TrackMetadata(
                  title: i % 10 == 0 ? 'Common title' : 'Track $i',
                  artist: 'Artist ${i % 100}',
                  durationMs: i % 17 == 0 ? null : 180000 + i % 1000,
                ),
              ),
          ]);
        }
        await repository.completeScan(session);
        expect(
          (await database
                  .customSelect('SELECT COUNT(*) AS n FROM local_tracks')
                  .getSingle())
              .read<int>('n'),
          count,
        );
        final unique = await repository.matchCandidates(
          title: 'Track 99999',
          durationMs: 180999,
          durationToleranceMs: 1,
        );
        expect(unique.timed.single.fileName, '99999.flac');
        final common = await repository.matchCandidates(
          title: 'Common title',
          durationMs: 180500,
          durationToleranceMs: 500,
          limitPerGroup: 20,
        );
        expect(common.timed.length, 20);
        expect(common.unmeasured.length, 20);
        expect(common.isTruncated, isTrue);
        final page = await repository.filesPage(afterId: 99000, limit: 50);
        expect(page.length, 50);
        expect(page.first.id, greaterThan(99000));
        final file = unique.timed.single;
        await repository.confirmSourceMatch(
          source: 'qq',
          sourceTrackId: 'scale-song',
          fileId: file.id,
          expectedRevision: file.revision,
          decision: MatchDecision.manual,
          matcherVersion: 1,
        );

        Future<List<String>> plan(
          String sql,
          List<Variable> variables,
        ) async => [
          for (final row
              in await database
                  .customSelect('EXPLAIN QUERY PLAN $sql', variables: variables)
                  .get())
            row.read<String>('detail'),
        ];
        void indexed(List<String> details, String expectedIndex) {
          final text = details.join('\n');
          expect(text, contains(expectedIndex));
          // 'SCAN ... USING INDEX' can still walk an entire index; require a search.
          expect(text, contains('SEARCH t'));
          expect(
            RegExp(r'\bSCAN [tl](?:\s|$)').hasMatch(text),
            isFalse,
            reason: text,
          );
          expect(text, isNot(contains('USE TEMP B-TREE')), reason: text);
        }

        indexed(
          await plan(LibrarySql.timedCandidates, [
            const Variable<int>(TrackNormalization.version),
            const Variable<String>('track 99999'),
            const Variable<int>(180998),
            const Variable<int>(181000),
            const Variable<int>(51),
          ]),
          'tracks_match_title_duration',
        );
        indexed(
          await plan(LibrarySql.unmeasuredCandidates, [
            const Variable<int>(TrackNormalization.version),
            const Variable<String>('common title'),
            const Variable<int>(51),
          ]),
          'tracks_match_title_duration',
        );
        indexed(
          await plan(LibrarySql.anyDurationCandidates, [
            const Variable<int>(TrackNormalization.version),
            const Variable<String>('common title'),
            const Variable<int>(51),
          ]),
          'tracks_match_title_duration',
        );
        indexed(
          await plan(LibrarySql.browse, [
            const Variable<int>(99000),
            const Variable<int>(50),
          ]),
          'tracks_present_page',
        );
        final linked = (await plan(LibrarySql.confirmedMatch, [
          const Variable<String>('qq'),
          const Variable<String>('scale-song'),
        ])).join('\n');
        expect(linked, contains('SEARCH l'));
        expect(
          RegExp(r'\bSCAN [tl](?:\s|$)').hasMatch(linked),
          isFalse,
          reason: linked,
        );
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

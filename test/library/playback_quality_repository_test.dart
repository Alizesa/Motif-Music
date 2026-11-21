import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/local_playback_matcher.dart';
import 'package:motif/settings/playback_quality_repository.dart';
import 'package:motif/settings/playback_quality_settings.dart';

import '../support/library_fixtures.dart';

const song = TrackMetadata(
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 180000,
);

ObservedAudioFile audio(
  int id, {
  int bitrate = 128,
  bool lossless = false,
  int durationMs = 180000,
}) => ObservedAudioFile(
  location: testAudio(id).location,
  fileName: '$id.flac',
  sizeBytes: 42,
  modifiedMs: 100,
  metadata: TrackMetadata(
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    durationMs: durationMs,
    bitrateKbps: bitrate,
    sampleRateHz: 44100,
    channels: 2,
    isLossless: lossless,
  ),
);

Future<void> seed(
  LibraryRepository repository,
  List<ObservedAudioFile> files,
) async {
  final root = await repository.addDirectory(
    location: testDirectory.location,
    displayName: 'Music',
  );
  final scan = await repository.beginScan(root.id);
  for (var offset = 0; offset < files.length; offset += 200) {
    await repository.writeScanBatch(
      scan,
      files.skip(offset).take(200).toList(),
    );
  }
  await repository.completeScan(scan);
}

void main() {
  // Migration comparisons use independent executors for old and fresh schemas.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test(
    'controller uses latest shared preference and explicit online quality',
    () async {
      final db = LibraryDatabase(NativeDatabase.memory());
      final controller = LibraryController(
        database: db,
        source: FakeLibrarySource(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      final repository = LibraryRepository(db);
      await seed(repository, [audio(1), audio(2, bitrate: 320)]);
      expect(
        await controller.playbackQualitySettings.loadMode(),
        PlaybackQualityMode.followOnline,
      );
      expect(
        (await controller.resolveLocalPlayback(track: song)).status,
        LocalPlaybackStatus.needsConfirmation,
      );
      expect(
        (await controller.resolveLocalPlayback(
          track: song,
          onlineQuality: audio(1).metadata!.quality,
        )).selected?.id,
        1,
      );
      await controller.playbackQualitySettings.saveMode(
        PlaybackQualityMode.highestLocal,
      );
      expect(
        (await controller.resolveLocalPlayback(
          track: song,
          onlineQuality: audio(1).metadata!.quality,
        )).selected?.id,
        2,
      );
      await controller.playbackQualitySettings.saveMode(
        PlaybackQualityMode.followOnline,
      );
      expect(
        (await controller.resolveLocalPlayback(
          track: song,
          onlineQuality: audio(1).metadata!.quality,
        )).selected?.id,
        1,
      );
    },
  );

  test('quality changes invalidate links, unchanged scans preserve fields, changed files clear fields', () async {
    final db = LibraryDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await seed(repository, [audio(1)]);
    final before = (await repository.filesPage()).single;
    expect(before.metadata.isLossless, isFalse);
    await repository.confirmSourceMatch(
      source: 'test',
      sourceTrackId: 'song',
      fileId: before.id,
      expectedRevision: before.revision,
      decision: MatchDecision.manual,
      matcherVersion: 1,
    );
    await seed(repository, [audio(1, bitrate: 320, lossless: true)]);
    final changed = (await repository.filesPage()).single;
    expect(changed.id, before.id);
    expect(changed.revision, before.revision + 1);
    expect(changed.quality.bitrateKbps, 320);
    expect(changed.quality.isLossless, isTrue);
    expect(
      await repository.confirmedMatch(source: 'test', sourceTrackId: 'song'),
      isNull,
    );
    final observed = ObservedAudioFile(
      location: before.location,
      fileName: before.fileName,
      sizeBytes: 42,
      modifiedMs: 100,
    );
    await seed(repository, [observed]);
    final unchanged = (await repository.filesPage()).single;
    expect(unchanged.revision, changed.revision);
    expect(unchanged.quality.bitrateKbps, 320);
    await seed(repository, [
      ObservedAudioFile(
        location: before.location,
        fileName: before.fileName,
        sizeBytes: 43,
        modifiedMs: 101,
      ),
    ]);
    final stale = (await repository.filesPage()).single;
    expect(stale.metadata.state, MetadataState.pending);
    expect(stale.quality.hasKnownMetric, isFalse);
    expect(stale.revision, changed.revision + 1);
  });

  test(
    'repository refuses to auto-select from a truncated indexed snapshot',
    () async {
      final db = LibraryDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = LibraryRepository(db);
      await seed(
        repository,
        List.generate(101, (i) => audio(i + 1, bitrate: 128 + i)),
      );
      final result = await repository.resolveLocalPlayback(
        track: song,
        mode: PlaybackQualityMode.highestLocal,
      );
      expect(result.reason, LocalPlaybackReason.truncatedCandidates);
      expect(result.selected, isNull);
      expect(result.candidates, hasLength(100));
    },
  );

  test('repository retains unknown-duration candidates for review and applies inclusive tolerance', () async {
    final db = LibraryDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await seed(repository, [
      audio(1, durationMs: 185000),
      audio(2, bitrate: 320, durationMs: 185001),
    ]);
    expect(
      (await repository.resolveLocalPlayback(
        track: song,
        mode: PlaybackQualityMode.highestLocal,
      )).selected?.id,
      1,
    );
    await seed(repository, [
      audio(1),
      ObservedAudioFile(
        location: testAudio(2).location,
        fileName: '2.flac',
        sizeBytes: 42,
        modifiedMs: 100,
        metadata: const TrackMetadata(
          title: 'Song',
          artist: 'Artist',
          album: 'Album',
        ),
      ),
    ]);
    final result = await repository.resolveLocalPlayback(
      track: song,
      mode: PlaybackQualityMode.highestLocal,
    );
    expect(result.reason, LocalPlaybackReason.incompleteMetadata);
    expect(result.candidates, hasLength(2));
  });

  test('v1 migration preserves data, refreshes quality safely, and persists settings across restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'motif-quality-migration-',
    );
    addTearDown(() => deleteTestDirectory(directory));
    final file = File.fromUri(directory.uri.resolve('library.sqlite'));
    final snapshot = jsonDecode(
      await File('drift_schemas/library/drift_schema_v1.json').readAsString(),
    ) as Map<String, dynamic>;
    final db = LibraryDatabase(
      NativeDatabase(
        file,
        setup: (raw) {
          for (final entity in snapshot['fixed_sql'] as List) {
            for (final statement in entity['sql'] as List) {
              raw.execute(statement['sql'] as String);
            }
          }
          raw.execute(
            "INSERT INTO library_roots(id, platform, location_key, locator, display_name) VALUES (7, 'windows', 'root', 'file:///C:/music', 'Music')",
          );
          raw.execute(
            "INSERT INTO local_tracks(id, platform, location_key, locator, file_name, title, artist, album, title_key, artist_key, album_key, duration_ms, metadata_state, size_bytes, modified_ms, revision) VALUES (42, 'windows', 'song', 'file:///C:/music/song.flac', 'song.flac', 'Song', 'Artist', 'Album', 'song', 'artist', 'album', 180000, 'ready', 42, 100, 9)",
          );
          raw.execute(
            "INSERT INTO root_files VALUES (7, 42, 0, 'file:///C:/music/song.flac')",
          );
          raw.execute(
            "INSERT INTO source_track_links VALUES ('test', 'song', 42, 9, 'manual', 1, 100)",
          );
          raw.execute('PRAGMA user_version = 1');
        },
      ),
    );
    var closed = false;
    addTearDown(() async {
      if (!closed) await db.close();
    });
    final repository = LibraryRepository(db);
    final migrated = (await repository.filesPage()).single;
    expect(migrated.id, 42);
    expect(migrated.revision, 9);
    expect(migrated.metadata.title, 'Song');
    expect(migrated.quality.hasKnownMetric, isFalse);
    expect((await repository.directories()).single.id, 7);
    expect(
      (await repository.confirmedMatch(
        source: 'test',
        sourceTrackId: 'song',
      ))?.id,
      42,
    );
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      2,
    );
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    final fresh = LibraryDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);
    for (final table in [
      'library_roots',
      'local_tracks',
      'root_files',
      'source_track_links',
      'playback_settings',
    ]) {
      expect(
        (await db.customSelect('PRAGMA table_info($table)').get())
            .map((r) => r.data)
            .toList(),
        (await fresh.customSelect('PRAGMA table_info($table)').get())
            .map((r) => r.data)
            .toList(),
      );
      expect(
        (await db.customSelect('PRAGMA foreign_key_list($table)').get())
            .map((r) => r.data)
            .toList(),
        (await fresh.customSelect('PRAGMA foreign_key_list($table)').get())
            .map((r) => r.data)
            .toList(),
      );
    }
    for (final assignment in [
      'bitrate_kbps = 0',
      'sample_rate_hz = -1',
      'channels = 0',
      'is_lossless = 2',
      "quality_read_state = 'bad'",
    ]) {
      await expectLater(
        db.customStatement('UPDATE local_tracks SET $assignment WHERE id = 42'),
        throwsA(isA<Exception>()),
      );
    }
    final settings = PlaybackQualitySettingsRepository(db);
    expect(await settings.loadMode(), PlaybackQualityMode.followOnline);
    await settings.saveMode(PlaybackQualityMode.highestLocal);

    Future<List<MetadataCandidate>> window({bool retry = false}) async =>
        (await repository.metadataWindow(
          afterId: 0,
          throughId: 42,
          includeFailed: retry,
        )).candidates;
    final initial = (await window()).single;
    expect(initial.isQualityRefresh, isTrue);
    expect(
      await repository.writeMetadata(
        initial,
        const TrackMetadata(state: MetadataState.failed),
      ),
      isTrue,
    );
    final preserved = (await repository.filesPage()).single;
    expect(preserved.metadata.title, 'Song');
    expect(preserved.metadata.state, MetadataState.ready);
    expect(preserved.revision, 9);
    expect(
      (await repository.confirmedMatch(
        source: 'test',
        sourceTrackId: 'song',
      ))?.id,
      42,
    );
    expect(await window(), isEmpty);
    final retry = (await window(retry: true)).single;
    expect(retry.qualityReadState, MetadataState.failed);
    expect(
      await repository.writeMetadata(initial, audio(1, bitrate: 320).metadata!),
      isFalse,
    );
    expect(
      await repository.writeMetadata(retry, audio(1, bitrate: 320).metadata!),
      isTrue,
    );
    final refreshed = (await repository.filesPage()).single;
    expect(refreshed.quality.bitrateKbps, 320);
    expect(refreshed.quality.sampleRateHz, 44100);
    expect(refreshed.quality.channels, 2);
    expect(refreshed.revision, 10);
    expect(
      await repository.confirmedMatch(source: 'test', sourceTrackId: 'song'),
      isNull,
    );
    expect(await window(retry: true), isEmpty);
    await db.close();
    closed = true;

    final reopened = LibraryDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      await PlaybackQualitySettingsRepository(reopened).loadMode(),
      PlaybackQualityMode.highestLocal,
    );
    expect(
      (await LibraryRepository(
        reopened,
      ).filesPage()).single.quality.bitrateKbps,
      320,
    );
  });
}

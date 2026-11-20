import 'package:drift/drift.dart';

import '../domain/library_models.dart';
import '../domain/track_normalization.dart';
import 'library_database.dart';
import 'library_sql.dart';

/// All file reads, writes and candidate queries are bounded. No all-tracks API.
/// This repository performs no network requests or audio/cover reads.
class LibraryRepository {
  LibraryRepository(this._database);

  static const maxBatchSize = 200;
  static const maxPageSize = 200;
  static const maxCandidatesPerGroup = 100;

  final LibraryDatabase _database;

  Future<LibraryDirectory> addDirectory({
    required FileLocation location,
    required String displayName,
  }) async {
    _validateLocation(location);
    await _database.customStatement(
      '''
      INSERT INTO library_roots(platform, location_key, locator, display_name)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(platform, location_key) DO UPDATE SET
        locator = excluded.locator, display_name = excluded.display_name,
        is_accessible = 1
    ''',
      [location.platform.name, location.key, location.locator, displayName],
    );
    final rows = await _select(
      '''
      SELECT * FROM library_roots WHERE platform = ? AND location_key = ?
    ''',
      [location.platform.name, location.key],
    );
    return _directory(rows.single);
  }

  Future<List<LibraryDirectory>> directories() async => [
    for (final row in await _select('SELECT * FROM library_roots ORDER BY id'))
      _directory(row),
  ];

  /// Call once during startup, before admitting new scans. No files are retired.
  Future<void> recoverInterruptedScans() => _database.customStatement('''
    UPDATE library_roots SET active_generation = NULL,
      last_scan_state = 'interrupted' WHERE active_generation IS NOT NULL
  ''');

  Future<ScanSession> beginScan(int rootId) => _database.transaction(() async {
    final roots = await _select('SELECT * FROM library_roots WHERE id = ?', [
      rootId,
    ]);
    if (roots.isEmpty) throw StateError('Directory does not exist: $rootId');
    final root = _directory(roots.single);
    if (root.activeGeneration != null) {
      throw StateError('Directory already has an active scan');
    }
    final generation = root.scanGeneration + 1;
    await _database.customStatement(
      '''
      UPDATE library_roots SET scan_generation = ?, active_generation = ?,
        last_scan_state = 'running' WHERE id = ?
    ''',
      [generation, generation, rootId],
    );
    return ScanSession(rootId: rootId, generation: generation);
  });

  /// Scanner asks only about the next batch, never builds a whole-library map.
  Future<Map<String, FileScanState>> scanStates(
    LibraryPlatform platform,
    List<String> keys,
  ) async {
    _checkLimit(keys.length, maxBatchSize, 'keys', allowZero: true);
    if (keys.isEmpty) return const {};
    final placeholders = List.filled(keys.length, '?').join(',');
    final rows = await _select(
      '''
      SELECT location_key, size_bytes, modified_ms, metadata_state,
        normalization_version, is_present FROM local_tracks
      WHERE platform = ? AND location_key IN ($placeholders)
    ''',
      [platform.name, ...keys],
    );
    return {
      for (final row in rows)
        row.read<String>('location_key'): FileScanState(
          key: row.read<String>('location_key'),
          sizeBytes: row.readNullable<int>('size_bytes'),
          modifiedMs: row.readNullable<int>('modified_ms'),
          metadataState: MetadataState.values.byName(
            row.read<String>('metadata_state'),
          ),
          normalizationVersion: row.read<int>('normalization_version'),
          isPresent: row.read<int>('is_present') == 1,
        ),
    };
  }

  /// Atomically records files and membership. Memory/work scale with this batch.
  Future<void> writeScanBatch(
    ScanSession session,
    List<ObservedAudioFile> files,
  ) async {
    _checkLimit(files.length, maxBatchSize, 'files', allowZero: true);
    final batchFiles = List<ObservedAudioFile>.of(files, growable: false);
    for (final file in batchFiles) {
      _validateLocation(file.location);
      if (file.sizeBytes != null && file.sizeBytes! < 0) {
        throw ArgumentError.value(file.sizeBytes, 'sizeBytes');
      }
      final tags = file.metadata;
      if (tags != null &&
          (tags.state == MetadataState.pending ||
              (tags.durationMs != null && tags.durationMs! <= 0))) {
        throw ArgumentError(
          'Metadata must be ready/failed with a positive or unknown duration',
        );
      }
    }
    await _database.transaction(() async {
      final root = await _requireSession(session);
      if (batchFiles.any(
        (f) => f.location.platform != root.location.platform,
      )) {
        throw ArgumentError(
          'A batch cannot contain files from a different platform',
        );
      }
      await _database.batch((batch) {
        for (final file in batchFiles) {
          final tags = file.metadata;
          batch.customStatement(LibrarySql.upsertFile, [
            file.location.platform.name,
            file.location.key,
            file.location.locator,
            file.fileName,
            file.sizeBytes,
            file.modifiedMs,
            tags?.title ?? '',
            tags?.artist ?? '',
            tags?.album ?? '',
            TrackNormalization.key(tags?.title ?? ''),
            TrackNormalization.key(tags?.artist ?? ''),
            TrackNormalization.key(tags?.album ?? ''),
            tags?.durationMs,
            tags?.container,
            tags?.codec,
            tags?.state.name ?? MetadataState.pending.name,
            TrackNormalization.version,
          ]);
          batch.customStatement(LibrarySql.markSeen, [
            session.rootId,
            session.generation,
            file.location.locator,
            file.location.platform.name,
            file.location.key,
          ]);
        }
      });
    });
  }

  /// Only call after a complete, successful traversal, never on cancel/error.
  Future<void> completeScan(ScanSession session) =>
      _database.transaction(() async {
        await _requireSession(session);
        await _database.customStatement(LibrarySql.retireUnseen, [
          session.rootId,
          session.generation,
          session.rootId,
          session.generation,
        ]);
        await _database.customStatement(
          '''
      DELETE FROM root_files WHERE root_id = ? AND seen_generation <> ?
    ''',
          [session.rootId, session.generation],
        );
        await _database.customStatement(
          '''
      UPDATE library_roots SET active_generation = NULL,
        last_scan_state = 'complete', last_completed_ms = ?, is_accessible = 1
      WHERE id = ?
    ''',
          [DateTime.now().millisecondsSinceEpoch, session.rootId],
        );
      });

  /// Cancellation preserves all memberships and records an interrupted scan.
  Future<void> interruptScan(ScanSession session) =>
      _database.transaction(() async {
        await _requireSession(session);
        await _database.customStatement(
          "UPDATE library_roots SET active_generation = NULL, last_scan_state = 'interrupted' WHERE id = ?",
          [session.rootId],
        );
      });

  /// A partial enumeration cannot prove any unseen file was deleted.
  Future<void> failScan(ScanSession session, {bool accessRevoked = false}) =>
      _database.transaction(() async {
        await _requireSession(session);
        await _database.customStatement(
          '''
      UPDATE library_roots SET active_generation = NULL, last_scan_state = 'failed',
        is_accessible = CASE WHEN ? = 1 THEN 0 ELSE is_accessible END
      WHERE id = ?
    ''',
          [accessRevoked ? 1 : 0, session.rootId],
        );
      });

  Future<void> removeDirectory(int rootId) => _database.transaction(() async {
    await _database.customStatement(
      '''
      UPDATE local_tracks SET is_present = 0
      WHERE id IN (SELECT file_id FROM root_files WHERE root_id = ?)
      AND NOT EXISTS (
        SELECT 1 FROM root_files other
        WHERE other.file_id = local_tracks.id AND other.root_id <> ?
      )
    ''',
      [rootId, rootId],
    );
    // Unavailable records are kept so re-adding the same file retains its ID.
    await _database.customStatement('DELETE FROM library_roots WHERE id = ?', [
      rootId,
    ]);
  });

  /// Cursor pagination; OFFSET and full result-list watchers are not used.
  Future<List<LocalAudioFile>> filesPage({
    int afterId = 0,
    int limit = 100,
  }) async {
    _checkLimit(limit, maxPageSize, 'limit');
    if (afterId < 0) throw ArgumentError.value(afterId, 'afterId');
    return [
      for (final row in await _select(LibrarySql.browse, [afterId, limit]))
        _file(row),
    ];
  }

  /// Re-resolves a visible row immediately before playback; stale rows cannot play.
  Future<LocalAudioFile?> fileById(int id) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    final rows = await _select(LibrarySql.fileById, [id]);
    return rows.isEmpty ? null : _file(rows.single);
  }

  /// Captures the finite job boundary without reading the library into memory.
  Future<int> metadataUpperBound() async => (await _select(
    'SELECT COALESCE(MAX(id), 0) AS last_id FROM local_tracks',
  )).single.read<int>('last_id');

  /// Each window visits at most [limit] present IDs, including ready rows.
  /// Sparse failures/pending rows therefore cannot cause repeated full scans.
  Future<MetadataWindow> metadataWindow({
    required int afterId,
    required int throughId,
    bool includeFailed = false,
    int limit = 100,
  }) async {
    _checkLimit(limit, maxPageSize, 'limit');
    if (afterId < 0 || throughId < 0) throw ArgumentError('Invalid ID range');
    final rows = await _select(LibrarySql.metadataWindow, [
      afterId,
      throughId,
      limit,
    ]);
    final ids = [
      for (final row in rows)
        if (row.read<String>('metadata_state') == 'pending' ||
            (includeFailed && row.read<String>('metadata_state') == 'failed'))
          row.read<int>('id'),
    ];
    // Ready windows carry only IDs/states; no ready tag strings or locators
    // cross the database boundary during startup continuation.
    final details = ids.isEmpty
        ? const <QueryRow>[]
        : await _select(
            LibrarySql.metadataDetails(List.filled(ids.length, '?').join(',')),
            [...ids, includeFailed ? 'failed' : 'pending'],
          );
    return MetadataWindow(
      afterId: rows.isEmpty ? throughId : rows.last.read<int>('id'),
      candidates: [
        for (final row in details)
          MetadataCandidate(
            file: _file(row),
            rootId: row.read<int>('metadata_root_id'),
            scanGeneration: row.read<int>('metadata_generation'),
          ),
      ],
    );
  }

  /// Compare-and-set: a rescan, removal, grant change or newer metadata wins.
  Future<bool> writeMetadata(
    MetadataCandidate candidate,
    TrackMetadata metadata,
  ) async {
    if (metadata.state == MetadataState.pending ||
        (metadata.durationMs != null && metadata.durationMs! <= 0)) {
      throw ArgumentError(
        'Metadata must be ready/failed with positive or unknown duration',
      );
    }
    final f = candidate.file;
    final rows = await _select(
      '''
      UPDATE local_tracks AS t SET title = ?, artist = ?, album = ?,
        title_key = ?, artist_key = ?, album_key = ?, duration_ms = ?,
        container = ?, codec = ?, metadata_state = ?, normalization_version = ?,
        revision = revision + 1
      WHERE t.id = ? AND t.revision = ? AND t.is_present = 1
        AND t.size_bytes IS ? AND t.modified_ms IS ?
        AND t.metadata_state = ?
        AND EXISTS (SELECT 1 FROM root_files rf
          JOIN library_roots r ON r.id = rf.root_id
          WHERE rf.file_id = t.id AND r.id = ? AND r.scan_generation = ?
            AND r.is_accessible = 1 AND r.active_generation IS NULL
            AND rf.file_locator = ?)
      RETURNING id
    ''',
      [
        metadata.title,
        metadata.artist,
        metadata.album,
        TrackNormalization.key(metadata.title),
        TrackNormalization.key(metadata.artist),
        TrackNormalization.key(metadata.album),
        metadata.durationMs,
        metadata.container,
        metadata.codec,
        metadata.state.name,
        TrackNormalization.version,
        f.id,
        f.revision,
        f.sizeBytes,
        f.modifiedMs,
        f.metadata.state.name,
        candidate.rootId,
        candidate.scanGeneration,
        f.location.locator,
      ],
    );
    return rows.isNotEmpty;
  }

  /// Retrieval only. No similarity score or automatic-match threshold is implied.
  /// No duration => candidates are all unmeasured relative to this request.
  Future<MatchCandidates> matchCandidates({
    required String title,
    int? durationMs,
    required int durationToleranceMs,
    int limitPerGroup = 50,
  }) async {
    _checkLimit(limitPerGroup, maxCandidatesPerGroup, 'limitPerGroup');
    if (durationToleranceMs < 0 || (durationMs != null && durationMs <= 0)) {
      throw ArgumentError(
        'Duration must be positive; tolerance cannot be negative',
      );
    }
    final titleKey = TrackNormalization.key(title);
    if (titleKey.isEmpty) {
      return MatchCandidates(timed: [], unmeasured: [], isTruncated: false);
    }
    final prefix = <Object?>[TrackNormalization.version, titleKey];
    final timed = durationMs == null
        ? <QueryRow>[]
        : await _select(LibrarySql.timedCandidates, [
            ...prefix,
            durationMs - durationToleranceMs,
            durationMs + durationToleranceMs,
            limitPerGroup + 1,
          ]);
    final unmeasured = await _select(
      durationMs == null
          ? LibrarySql.anyDurationCandidates
          : LibrarySql.unmeasuredCandidates,
      [...prefix, limitPerGroup + 1],
    );
    return MatchCandidates(
      timed: timed.take(limitPerGroup).map(_file).toList(),
      unmeasured: unmeasured.take(limitPerGroup).map(_file).toList(),
      isTruncated:
          timed.length > limitPerGroup || unmeasured.length > limitPerGroup,
    );
  }

  /// Revisions prevent a stale UI result from confirming a changed file.
  Future<void> confirmSourceMatch({
    required String source,
    required String sourceTrackId,
    required int fileId,
    required int expectedRevision,
    required MatchDecision decision,
    required int matcherVersion,
  }) async {
    _validateSource(source, sourceTrackId);
    if (matcherVersion <= 0) {
      throw ArgumentError.value(matcherVersion, 'matcherVersion');
    }
    await _database.transaction(() async {
      final files = await _select(
        '''
        SELECT t.* FROM local_tracks t
        WHERE t.id = ? AND t.revision = ? AND t.is_present = 1
          AND ${LibrarySql.accessibleFile}
      ''',
        [fileId, expectedRevision],
      );
      if (files.isEmpty) {
        throw StateError(
          'File changed or became unavailable before confirmation',
        );
      }
      // Do not expose pending/failed metadata as an automatic association.
      if (decision == MatchDecision.automatic &&
          files.single.read<String>('metadata_state') !=
              MetadataState.ready.name) {
        throw StateError('Automatic association requires verified metadata');
      }
      await _database.customStatement(
        '''
        INSERT INTO source_track_links(source, source_track_id, file_id,
          file_revision, decision, matcher_version, confirmed_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, source_track_id) DO UPDATE SET
          file_id = excluded.file_id, file_revision = excluded.file_revision,
          decision = excluded.decision, matcher_version = excluded.matcher_version,
          confirmed_ms = excluded.confirmed_ms
      ''',
        [
          source,
          sourceTrackId,
          fileId,
          expectedRevision,
          decision.name,
          matcherVersion,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    });
  }

  /// The caller MUST still check the physical file/SAF grant before playback.
  /// A hit allows a later playback resolver to avoid resolving an online URL.
  Future<LocalAudioFile?> confirmedMatch({
    required String source,
    required String sourceTrackId,
  }) async {
    _validateSource(source, sourceTrackId);
    final rows = await _select(LibrarySql.confirmedMatch, [
      source,
      sourceTrackId,
    ]);
    return rows.isEmpty ? null : _file(rows.single);
  }

  Future<LibraryDirectory> _requireSession(ScanSession session) async {
    final rows = await _select(
      '''
      SELECT * FROM library_roots WHERE id = ? AND active_generation = ?
    ''',
      [session.rootId, session.generation],
    );
    if (rows.isEmpty) throw StateError('Scan session is no longer active');
    return _directory(rows.single);
  }

  Future<List<QueryRow>> _select(
    String sql, [
    List<Object?> values = const [],
  ]) => _database
      .customSelect(
        sql,
        variables: [
          for (final value in values)
            switch (value) {
              int n => Variable<int>(n),
              String s => Variable<String>(s),
              null => const Variable<String>(null),
              _ => throw ArgumentError.value(value, 'SQL parameter'),
            },
        ],
      )
      .get();

  static LibraryDirectory _directory(QueryRow row) => LibraryDirectory(
    id: row.read<int>('id'),
    location: _location(row),
    displayName: row.read<String>('display_name'),
    isAccessible: row.read<int>('is_accessible') == 1,
    scanGeneration: row.read<int>('scan_generation'),
    activeGeneration: row.readNullable<int>('active_generation'),
    lastScanState: row.read<String>('last_scan_state'),
  );

  static FileLocation _location(QueryRow row) => FileLocation(
    platform: LibraryPlatform.values.byName(row.read<String>('platform')),
    key: row.read<String>('location_key'),
    locator: row.read<String>('locator'),
  );

  static LocalAudioFile _file(QueryRow row) => LocalAudioFile(
    id: row.read<int>('id'),
    location: FileLocation(
      platform: LibraryPlatform.values.byName(row.read<String>('platform')),
      key: row.read<String>('location_key'),
      locator: row.read<String>('playable_locator'),
    ),
    fileName: row.read<String>('file_name'),
    sizeBytes: row.readNullable<int>('size_bytes'),
    modifiedMs: row.readNullable<int>('modified_ms'),
    metadata: TrackMetadata(
      title: row.read<String>('title'),
      artist: row.read<String>('artist'),
      album: row.read<String>('album'),
      durationMs: row.readNullable<int>('duration_ms'),
      container: row.readNullable<String>('container'),
      codec: row.readNullable<String>('codec'),
      state: MetadataState.values.byName(row.read<String>('metadata_state')),
    ),
    revision: row.read<int>('revision'),
    normalizationVersion: row.read<int>('normalization_version'),
    isPresent: row.read<int>('is_present') == 1,
  );

  static void _validateLocation(FileLocation location) {
    if (location.key.trim().isEmpty || location.locator.trim().isEmpty) {
      throw ArgumentError('Location key and locator cannot be empty');
    }
  }

  static void _validateSource(String source, String sourceTrackId) {
    if (source.trim().isEmpty || sourceTrackId.trim().isEmpty) {
      throw ArgumentError('Source and source track ID cannot be empty');
    }
  }

  static void _checkLimit(
    int value,
    int max,
    String name, {
    bool allowZero = false,
  }) {
    if (value < (allowZero ? 0 : 1) || value > max) {
      throw ArgumentError.value(value, name, 'Maximum is $max');
    }
  }
}

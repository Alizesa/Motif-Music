/// Shared with query-plan tests so tests exercise the production SQL.
abstract final class LibrarySql {
  static const accessibleFile = '''
    EXISTS (
      SELECT 1 FROM root_files rf
      JOIN library_roots r ON r.id = rf.root_id
      WHERE rf.file_id = t.id AND r.is_accessible = 1
    )
  ''';

  // A SAF document can have different playable URIs under different tree grants.
  static const playableLocator = '''
    (SELECT rf.file_locator FROM root_files rf
     JOIN library_roots r ON r.id = rf.root_id
     WHERE rf.file_id = t.id AND r.is_accessible = 1
     ORDER BY rf.root_id LIMIT 1)
  ''';

  static const browse =
      '''
    SELECT t.*, $playableLocator AS playable_locator FROM local_tracks t
    WHERE t.is_present = 1 AND t.id > ? AND $accessibleFile
    ORDER BY t.id LIMIT ?
  ''';

  static const fileById =
      '''
    SELECT t.*, $playableLocator AS playable_locator FROM local_tracks t
    WHERE t.id = ? AND t.is_present = 1 AND $accessibleFile
  ''';
  static const timedCandidates =
      '''
    SELECT t.*, $playableLocator AS playable_locator FROM local_tracks t
    WHERE t.is_present = 1 AND t.metadata_state = 'ready'
      AND t.title_key <> '' AND t.normalization_version = ? AND t.title_key = ?
      AND t.duration_ms BETWEEN ? AND ? AND $accessibleFile
    ORDER BY t.duration_ms, t.id LIMIT ?
  ''';

  static const unmeasuredCandidates =
      '''
    SELECT t.*, $playableLocator AS playable_locator FROM local_tracks t
    WHERE t.is_present = 1 AND t.metadata_state = 'ready'
      AND t.title_key <> '' AND t.normalization_version = ? AND t.title_key = ?
      AND t.duration_ms IS NULL AND $accessibleFile
    ORDER BY t.id LIMIT ?
  ''';

  static const anyDurationCandidates =
      '''
    SELECT t.*, $playableLocator AS playable_locator FROM local_tracks t
    WHERE t.is_present = 1 AND t.metadata_state = 'ready'
      AND t.title_key <> '' AND t.normalization_version = ? AND t.title_key = ?
      AND $accessibleFile
    ORDER BY t.duration_ms, t.id LIMIT ?
  ''';

  static const confirmedMatch =
      '''
    SELECT t.*, $playableLocator AS playable_locator FROM source_track_links l
    JOIN local_tracks t ON t.id = l.file_id AND t.revision = l.file_revision
    WHERE l.source = ? AND l.source_track_id = ?
      AND t.is_present = 1 AND $accessibleFile
  ''';

  // ID range scans reuse tracks_present_page, including sparse pending pages.
  // The cursor advances past every inspected row, not only pending candidates.
  static const metadataWindow = '''
    SELECT t.id, t.metadata_state FROM local_tracks t
    WHERE t.is_present = 1 AND t.id > ? AND t.id <= ?
    ORDER BY t.id LIMIT ?
  ''';

  static String metadataDetails(String placeholders) =>
      '''
    SELECT t.*, rf.file_locator AS playable_locator,
      r.id AS metadata_root_id, r.scan_generation AS metadata_generation
    FROM local_tracks t
    JOIN root_files rf ON rf.file_id = t.id AND rf.root_id = (
      SELECT MIN(r2.id) FROM root_files rf2
      JOIN library_roots r2 ON r2.id = rf2.root_id
      WHERE rf2.file_id = t.id AND r2.is_accessible = 1
        AND r2.active_generation IS NULL
    )
    JOIN library_roots r ON r.id = rf.root_id
    WHERE t.id IN ($placeholders) AND t.is_present = 1
      AND t.metadata_state IN ('pending', ?)
    ORDER BY t.id
  ''';

  // Never INSERT OR REPLACE: it deletes rows and would break stable file IDs.
  static const upsertFile =
      '''
    INSERT INTO local_tracks (
      platform, location_key, locator, file_name, size_bytes, modified_ms,
      title, artist, album, title_key, artist_key, album_key, duration_ms,
      container, codec, metadata_state, normalization_version
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(platform, location_key) DO UPDATE SET
      locator = excluded.locator, file_name = excluded.file_name,
      size_bytes = excluded.size_bytes, modified_ms = excluded.modified_ms,
      revision = local_tracks.revision + CASE WHEN
        local_tracks.is_present = 0 OR
        local_tracks.normalization_version <> excluded.normalization_version OR
        (excluded.metadata_state = 'pending' AND
          (excluded.size_bytes IS NULL OR excluded.modified_ms IS NULL)) OR
        local_tracks.size_bytes IS NOT excluded.size_bytes OR
        local_tracks.modified_ms IS NOT excluded.modified_ms OR (
          excluded.metadata_state <> 'pending' AND (
            local_tracks.title IS NOT excluded.title OR
            local_tracks.artist IS NOT excluded.artist OR
            local_tracks.album IS NOT excluded.album OR
            local_tracks.duration_ms IS NOT excluded.duration_ms OR
            local_tracks.container IS NOT excluded.container OR
            local_tracks.codec IS NOT excluded.codec OR
            local_tracks.metadata_state IS NOT excluded.metadata_state OR
            local_tracks.normalization_version <> excluded.normalization_version
          )
        ) THEN 1 ELSE 0 END,
      title = CASE WHEN $replaceMetadata THEN excluded.title ELSE local_tracks.title END,
      artist = CASE WHEN $replaceMetadata THEN excluded.artist ELSE local_tracks.artist END,
      album = CASE WHEN $replaceMetadata THEN excluded.album ELSE local_tracks.album END,
      title_key = CASE WHEN $replaceMetadata THEN excluded.title_key ELSE local_tracks.title_key END,
      artist_key = CASE WHEN $replaceMetadata THEN excluded.artist_key ELSE local_tracks.artist_key END,
      album_key = CASE WHEN $replaceMetadata THEN excluded.album_key ELSE local_tracks.album_key END,
      duration_ms = CASE WHEN $replaceMetadata THEN excluded.duration_ms ELSE local_tracks.duration_ms END,
      container = CASE WHEN $replaceMetadata THEN excluded.container ELSE local_tracks.container END,
      codec = CASE WHEN $replaceMetadata THEN excluded.codec ELSE local_tracks.codec END,
      metadata_state = CASE WHEN $replaceMetadata THEN excluded.metadata_state ELSE local_tracks.metadata_state END,
      normalization_version = CASE WHEN $replaceMetadata THEN excluded.normalization_version ELSE local_tracks.normalization_version END,
      is_present = 1
  ''';

  // All expressions see the pre-update row, including size and modification time.
  static const replaceMetadata = '''
    excluded.metadata_state <> 'pending' OR
    local_tracks.is_present = 0 OR
    local_tracks.normalization_version <> excluded.normalization_version OR
    excluded.size_bytes IS NULL OR excluded.modified_ms IS NULL OR
    local_tracks.size_bytes IS NOT excluded.size_bytes OR
    local_tracks.modified_ms IS NOT excluded.modified_ms
  ''';

  static const markSeen = '''
    INSERT INTO root_files(root_id, file_id, seen_generation, file_locator)
    SELECT ?, id, ?, ? FROM local_tracks WHERE platform = ? AND location_key = ?
    ON CONFLICT(root_id, file_id) DO UPDATE SET
      seen_generation = excluded.seen_generation, file_locator = excluded.file_locator
  ''';

  // Scope removal to this root's stale members, rather than scanning all tracks.
  static const retireUnseen = '''
    UPDATE local_tracks SET is_present = 0
    WHERE id IN (
      SELECT file_id FROM root_files WHERE root_id = ? AND seen_generation <> ?
    ) AND NOT EXISTS (
      SELECT 1 FROM root_files other WHERE other.file_id = local_tracks.id
        AND NOT (other.root_id = ? AND other.seen_generation <> ?)
    )
  ''';
}

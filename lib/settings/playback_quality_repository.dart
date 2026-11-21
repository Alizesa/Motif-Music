import '../library/data/library_database.dart';
import 'playback_quality_settings.dart';

class PlaybackQualitySettingsRepository {
  const PlaybackQualitySettingsRepository(this._database);

  final LibraryDatabase _database;

  Future<PlaybackQualityMode> loadMode() async {
    final row = await _database
        .customSelect(
          'SELECT local_quality_mode FROM playback_settings WHERE id = 1',
        )
        .getSingleOrNull();
    return row?.read<String>('local_quality_mode') == 'highestLocal'
        ? PlaybackQualityMode.highestLocal
        : PlaybackQualityMode.followOnline;
  }

  Future<void> saveMode(PlaybackQualityMode mode) => _database.customStatement(
    '''
    INSERT INTO playback_settings(id, local_quality_mode) VALUES (1, ?)
    ON CONFLICT(id) DO UPDATE SET local_quality_mode = excluded.local_quality_mode
    ''',
    [mode.name],
  );
}

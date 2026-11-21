import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/track_normalization.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/qq/qq_track.dart';
import 'package:motif/settings/online_playback_preferences.dart';

QqTrack playbackTrack(int id) => QqTrack(
  mid: 'songMid$id',
  title: 'Song $id',
  artists: const ['Artist'],
  album: 'Album',
  mediaMid: 'mediaMid$id',
  durationMs: 180000,
);

LocalAudioFile playbackFile(int id, {int bitrate = 128}) => LocalAudioFile(
  id: id,
  location: FileLocation(
    platform: LibraryPlatform.windows,
    key: 'file-$id',
    locator: 'file:///C:/music/song-$id.mp3',
  ),
  fileName: 'song-$id.mp3',
  sizeBytes: 1000,
  modifiedMs: 1,
  metadata: TrackMetadata(
    title: 'Song 1',
    artist: 'Artist',
    album: 'Album',
    durationMs: 180000,
    bitrateKbps: bitrate,
    sampleRateHz: 44100,
    channels: 2,
    isLossless: false,
  ),
  revision: 1,
  normalizationVersion: TrackNormalization.version,
  isPresent: true,
);

class FakePlaybackSource implements PlaybackUrlResolver {
  FakePlaybackSource(this.sourceId);

  @override
  final String sourceId;
  final calls = <(QqTrack, OnlineQuality)>[];
  Future<OnlineStream> Function(QqTrack, OnlineQuality)? reply;
  int closeCount = 0;

  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) async {
    calls.add((track, quality));
    if (reply != null) return reply!(track, quality);
    return OnlineStream(
      uri: Uri.https('audio.example', '/${track.mid}.mp3'),
      sourceId: sourceId,
      requestedQuality: quality,
    );
  }

  @override
  void close() => closeCount++;
}

class MemoryPlaybackPreferencesStore implements OnlinePlaybackPreferencesStore {
  OnlinePlaybackPreferences value = const OnlinePlaybackPreferences();
  Object? loadError;
  Object? saveError;
  Future<void>? saveWait;
  int saves = 0;

  @override
  Future<OnlinePlaybackPreferences> load() async {
    if (loadError case final error?) throw error;
    return value;
  }

  @override
  Future<void> save(OnlinePlaybackPreferences preferences) async {
    saves++;
    if (saveWait case final pending?) await pending;
    if (saveError case final error?) throw error;
    value = preferences;
  }
}

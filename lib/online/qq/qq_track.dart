import '../../library/domain/library_models.dart';
import '../domain/playback_source.dart';

class QqTrack {
  QqTrack({
    required this.mid,
    required this.title,
    required List<String> artists,
    required this.album,
    this.songId,
    this.albumMid,
    this.mediaMid,
    this.durationMs,
    this.songType = 0,
    Map<OnlineQuality, int> qualitySizes = const {},
  }) : artists = List.unmodifiable(artists),
       qualitySizes = Map.unmodifiable(qualitySizes);

  final String mid;
  final int? songId;
  final String title;
  final List<String> artists;
  final String album;
  final String? albumMid;
  final String? mediaMid;
  final int? durationMs;
  final int songType;

  String get identity => 'qq:$songType:$mid';

  /// Availability hints from the catalog, not proven playback entitlements or
  /// bitrate/sample-rate measurements. Never use these sizes to infer quality.
  final Map<OnlineQuality, int> qualitySizes;

  TrackMetadata get metadata => TrackMetadata(
    title: title,
    artist: artists.join('、'),
    album: album,
    durationMs: durationMs,
  );
}

class QqSearchPage {
  QqSearchPage({
    required List<QqTrack> tracks,
    required this.page,
    required this.hasMore,
    this.total,
  }) : tracks = List.unmodifiable(tracks);
  final List<QqTrack> tracks;
  final int page;
  final bool hasMore;
  final int? total;
}

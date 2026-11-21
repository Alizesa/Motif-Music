import 'qq_track.dart';

/// A compact feed reference has a catalog ID, never a fabricated playback MID.
class QqRecommendedSong {
  QqRecommendedSong({
    required this.title,
    required List<String> artists,
    this.track,
    this.songId,
    this.album = '',
    this.artwork,
  }) : artists = List.unmodifiable(artists);
  final String title;
  final List<String> artists;
  final QqTrack? track;
  final int? songId;
  final String album;
  final Uri? artwork;
  String get identity => track?.identity ?? 'qq:catalog:$songId';
}

class QqPlaylist {
  const QqPlaylist({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.artwork,
    this.count,
  });
  final String id;
  final String title;
  final String subtitle;
  final Uri? artwork;
  final int? count;
}

class QqSongShelf {
  QqSongShelf({
    required this.id,
    required this.title,
    required List<List<QqRecommendedSong>> pages,
  }) : pages = List.unmodifiable(
         pages.map((page) => List<QqRecommendedSong>.unmodifiable(page)),
       );
  final String id;
  final String title;
  final List<List<QqRecommendedSong>> pages;
}

class QqHomeFeed {
  QqHomeFeed({
    required List<QqSongShelf> shelves,
    required List<QqPlaylist> playlists,
    required List<String> shelfIds,
    required List<String> uniqueKeys,
    required this.shelfCount,
    required this.page,
    required this.hasMore,
  }) : shelves = List.unmodifiable(shelves),
       playlists = List.unmodifiable(playlists),
       shelfIds = List.unmodifiable(shelfIds),
       uniqueKeys = List.unmodifiable(uniqueKeys);
  final List<QqSongShelf> shelves;
  final List<QqPlaylist> playlists;
  final List<String> shelfIds;
  final List<String> uniqueKeys;
  final int shelfCount;
  final int page;
  final bool hasMore;
}

class QqPlaylistPage {
  QqPlaylistPage({
    required List<QqTrack> tracks,
    required this.offset,
    required this.hasMore,
    this.total,
  }) : tracks = List.unmodifiable(tracks);
  final List<QqTrack> tracks;
  final int offset;
  final bool hasMore;
  final int? total;
}

import 'dart:convert';

import '../domain/online_error.dart';
import 'auth/qq_credential.dart' show qqAvatar;
import 'qq_home_models.dart';
import 'qq_response_parser.dart';
import 'qq_track.dart';

Map<String, Object?>? _object(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is String && value.length < 65536) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

List<Object?>? _array(Object? value) {
  if (value is List) return value.cast<Object?>();
  if (value is String && value.length < 65536) {
    try {
      final decoded = jsonDecode(value);
      return decoded is List ? decoded.cast<Object?>() : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

QqRecommendedSong? parseQqRecommendedSong(
  Object? value, {
  String? fallbackTitle,
  Uri? artwork,
}) {
  var item = _object(value);
  if (item == null) return null;
  item = _object(item['track']) ?? _object(item['Track']) ?? item;
  if (item.containsKey('MID')) {
    item = {
      ...item,
      'mid': item['MID'],
      'id': item['ID'],
      'name': item['Name'],
      'singer': [
        {'name': item['SingerName']},
      ],
      'albumname': item['AlbumName'],
      'albummid': item['AlbumMID'],
    };
  }
  try {
    final track = parseQqTrack(item);
    return QqRecommendedSong(
      title: track.title,
      artists: track.artists,
      album: track.album,
      track: track,
      songId: track.songId,
      artwork: qqAvatar(item['Cover']) ?? artwork,
    );
  } on OnlineException {
    final id = qqInt(item['ID']) ?? qqInt(item['id']) ?? qqInt(item['songid']);
    final title =
        qqText(item['Name']) ??
        qqText(item['name']) ??
        qqText(item['title']) ??
        fallbackTitle;
    if (id == null || id <= 0 || title == null || title.isEmpty) return null;
    final artist = qqText(item['SingerName']) ?? qqText(item['subtitle']);
    return QqRecommendedSong(
      title: title,
      artists: artist == null ? [] : [artist],
      songId: id,
      album: qqText(item['AlbumName']) ?? '',
      artwork: qqAvatar(item['Cover']) ?? artwork,
    );
  }
}

List<QqTrack> parseQqTrackList(Object? value, {required int limit}) {
  final values = _array(value);
  if (values == null) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final tracks = <String, QqTrack>{};
  for (final raw in values.take(limit)) {
    final item = _object(raw);
    if (item == null) continue;
    try {
      final track = parseQqTrack(
        _object(item['track']) ??
            _object(item['Track']) ??
            _object(item['songInfo']) ??
            _object(item['song']) ??
            _object(item['data']) ??
            item,
      );
      tracks.putIfAbsent(track.identity, () => track);
    } on OnlineException {
      // Preserve valid siblings without inventing missing catalog identities.
    }
  }
  if (values.isNotEmpty && tracks.isEmpty) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  return List.unmodifiable(tracks.values);
}

List<QqPlaylist> parseQqPersonalizedPlaylists(Map<String, Object?> data) {
  final values = _array(data['List']);
  if (values == null) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final playlists = <String, QqPlaylist>{};
  for (final raw in values.take(24)) {
    final item = _object(raw);
    final playlist = _object(item?['Playlist']) ?? _object(item?['playlist']);
    final basic = _object(playlist?['basic']);
    if (basic == null) continue;
    final id = '${basic['tid'] ?? basic['dissid'] ?? basic['id'] ?? ''}';
    final title =
        qqText(basic['title']) ??
        qqText(basic['dissname']) ??
        qqText(basic['name']);
    if (!RegExp(r'^\d{1,20}$').hasMatch(id) ||
        int.tryParse(id) == null ||
        int.parse(id) <= 0 ||
        title == null) {
      continue;
    }
    final creator = _object(basic['creator']);
    final cover = _object(basic['cover']);
    playlists[id] = QqPlaylist(
      id: id,
      title: title,
      count: qqInt(basic['song_cnt']) ?? qqInt(basic['song_count']),
      subtitle: qqText(creator?['nick']) ?? qqText(creator?['nickname']) ?? '',
      artwork: qqAvatar(
        cover?['medium_url'] ??
            cover?['default_url'] ??
            basic['diss_cover'] ??
            basic['cover_url'],
      ),
    );
  }
  return List.unmodifiable(playlists.values);
}

List<Object?>? qqRecentPlaylistEntries(Map<String, Object?> responseData) =>
    _array(_object(responseData['data'])?['geDanList']);

List<QqPlaylist> parseQqRecentPlaylists(Map<String, Object?> responseData) {
  final values = qqRecentPlaylistEntries(responseData);
  if (values == null) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final playlists = <(int, int, QqPlaylist)>[];
  final seen = <String>{};
  for (final raw in values.take(500)) {
    final item = _object(raw);
    if (item == null) continue;
    final id = '${item['id'] ?? ''}';
    final title = qqText(item['name']);
    if (!RegExp(r'^\d{1,20}$').hasMatch(id) ||
        (int.tryParse(id) ?? 0) <= 0 ||
        title == null ||
        !seen.add(id)) {
      continue;
    }
    playlists.add((
      qqInt(item['index']) ?? 99999,
      qqInt(item['lastTime']) ?? 0,
      QqPlaylist(
        id: id,
        title: title,
        count: qqInt(item['num']),
        artwork: qqAvatar(item['pic'] ?? item['albumPicUrl']),
      ),
    ));
  }
  playlists.sort((a, b) {
    final order = a.$1.compareTo(b.$1);
    return order != 0 ? order : b.$2.compareTo(a.$2);
  });
  return List.unmodifiable(playlists.map((value) => value.$3));
}

QqHomeFeed parseQqHomeFeed(Map<String, Object?> data, {required int page}) {
  final shelves = _array(data['v_shelf']) ?? _array(data['Shelfs']);
  if (shelves == null) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final ids = <String>[];
  final keys = <String>[];
  final results = <QqSongShelf>[];
  final playlists = <String, QqPlaylist>{};
  for (final raw in shelves.take(40)) {
    final shelf = _object(raw);
    if (shelf == null) continue;
    final id = '${shelf['id'] ?? ''}';
    if (id.isNotEmpty) ids.add(id);
    final title =
        (qqText(shelf['title_template']) ?? qqText(shelf['title']) ?? '')
            .replaceAll('{String}', qqText(shelf['title_content']) ?? '')
            .replaceAll('{string}', qqText(shelf['title_content']) ?? '');
    if (title.replaceAll(RegExp(r'\s+'), '') == '今日专属精彩节目') continue;
    final pages = <List<QqRecommendedSong>>[];
    for (final nicheRaw in (_array(shelf['v_niche']) ?? []).take(30)) {
      final niche = _object(nicheRaw);
      final songs = <QqRecommendedSong>[];
      for (final cardRaw in (_array(niche?['v_card']) ?? []).take(60)) {
        final card = _object(cardRaw);
        if (card == null) continue;
        final style = qqInt(card['style']) ?? -1;
        final type = qqInt(card['type']) ?? 0;
        final subType = qqInt(card['subtype']) ?? 0;
        final cardId = '${card['id'] ?? ''}';
        if (id == '315' && card['type'] != null) {
          keys.add('${type}_${subType}_$cardId');
        }
        if (type == 1700 || type == 400 && subType == 410) continue;
        final cardTitle = qqText(card['title']) ?? '';
        if (cardTitle.contains('每日30') || cardTitle == '每日推荐') continue;
        final extra = _object(card['card_extra_info']);
        final values =
            _array(extra?['Tracks']) ??
            _array(extra?['SongList']) ??
            (_object(card['track']) != null
                ? [card['track']]
                : _object(card['Track']) != null
                ? [card['Track']]
                : []);
        final cover = qqAvatar(card['cover']);
        final tracks = <QqRecommendedSong>[];
        for (final value in values.take(3)) {
          final track = parseQqRecommendedSong(value, artwork: cover);
          if (track != null) tracks.add(track);
        }
        if (tracks.isNotEmpty) {
          songs.addAll(tracks);
          continue;
        }
        if (type == 200 || {208, 301, 5105}.contains(style)) {
          final song = parseQqRecommendedSong({
            'id': style == 5105 ? card['subid'] : card['id'],
            'title': card['title'],
            'subtitle': card['subtitle'],
          }, artwork: cover);
          if (song != null) songs.add(song);
        } else if ((type == 500 ||
                {
                  1,
                  2,
                  5,
                  47,
                  54,
                  55,
                  84,
                  93,
                  201,
                  205,
                  210,
                  241,
                  302,
                }.contains(style)) &&
            (int.tryParse(cardId) ?? 0) > 0 &&
            cardTitle.isNotEmpty) {
          playlists[cardId] = QqPlaylist(
            id: cardId,
            title: cardTitle,
            subtitle: qqText(card['subtitle']) ?? '',
            count: qqInt(card['cnt']),
            artwork: cover,
          );
        }
      }
      final seen = <String>{};
      final unique = songs
          .where((song) => seen.add(song.identity))
          .take(18)
          .toList();
      for (var start = 0; start < unique.length; start += 3) {
        pages.add(unique.skip(start).take(3).toList());
      }
    }
    if (pages.isNotEmpty) {
      results.add(QqSongShelf(id: id, title: title, pages: pages));
    }
  }
  return QqHomeFeed(
    shelves: results,
    playlists: playlists.values.toList(),
    shelfIds: ids,
    uniqueKeys: keys.toSet().take(100).toList(),
    shelfCount: shelves.length,
    page: page,
    hasMore: shelves.isNotEmpty,
  );
}

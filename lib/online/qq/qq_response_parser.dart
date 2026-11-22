import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import 'qq_track.dart';

Map<String, Object?> qqObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  return value;
}

String? qqText(Object? value) {
  if (value is! String || value.trim().isEmpty || value == 'null') return null;
  return value.trim().replaceAllMapped(
    RegExp(r'&(?:amp|quot|apos|lt|gt|#\d{1,7}|#x[0-9a-fA-F]{1,6});'),
    (match) {
      final token = match[0]!;
      const named = {
        '&amp;': '&',
        '&quot;': '"',
        '&apos;': "'",
        '&lt;': '<',
        '&gt;': '>',
      };
      if (named.containsKey(token)) return named[token]!;
      final hex = token.startsWith('&#x');
      final code = int.tryParse(
        token.substring(hex ? 3 : 2, token.length - 1),
        radix: hex ? 16 : 10,
      );
      return code != null &&
              code > 0 &&
              code <= 0x10ffff &&
              !(code >= 0xd800 && code <= 0xdfff)
          ? String.fromCharCode(code)
          : token;
    },
  );
}

int? qqInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

bool validQqMid(String value) => RegExp(r'^[a-zA-Z0-9]{1,64}$').hasMatch(value);

QqTrack parseQqTrack(Object? value) {
  final item = qqObject(value);
  final mid = qqText(item['songmid']) ?? qqText(item['mid']);
  var title =
      qqText(item['songname']) ?? qqText(item['name']) ?? qqText(item['title']);
  if (mid == null || !validQqMid(mid) || title == null) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final subtitle = qqText(item['subtitle']);
  if (subtitle != null && !title.contains(subtitle)) {
    title = '$title ($subtitle)';
  }
  final album = item['album'] is Map<String, Object?>
      ? qqObject(item['album'])
      : const <String, Object?>{};
  final file = item['file'] is Map<String, Object?>
      ? qqObject(item['file'])
      : const <String, Object?>{};
  final artists = <String>[];
  if (item['singer'] case final List singers) {
    for (final singer in singers.take(100)) {
      if (singer is Map<String, Object?>) {
        final name = qqText(singer['name']);
        if (name != null && !artists.contains(name)) artists.add(name);
      }
    }
  }
  final duration = qqInt(item['interval']);
  final songId = qqInt(item['songid']) ?? qqInt(item['id']);
  final type = qqInt(item['type']) ?? qqInt(item['songtype']) ?? 0;
  final rawAlbumMid = qqText(item['albummid']) ?? qqText(album['mid']);
  final rawMediaMid = qqText(file['media_mid']) ?? qqText(item['strMediaMid']);
  final qualitySizes = <OnlineQuality, int>{};
  const fields = {
    OnlineQuality.standard: ('size128', 'size_128mp3'),
    OnlineQuality.high: ('size320', 'size_320mp3'),
    OnlineQuality.lossless: ('sizeflac', 'size_flac'),
    OnlineQuality.hiRes: ('sizehires', 'size_hires'),
  };
  for (final entry in fields.entries) {
    final size = qqInt(file[entry.value.$2]) ?? qqInt(item[entry.value.$1]);
    if (size != null && size > 0) qualitySizes[entry.key] = size;
  }
  return QqTrack(
    mid: mid,
    songId: songId != null && songId > 0 ? songId : null,
    title: title,
    artists: artists,
    album: qqText(item['albumname']) ?? qqText(album['name']) ?? '',
    albumMid: rawAlbumMid != null && validQqMid(rawAlbumMid)
        ? rawAlbumMid
        : null,
    mediaMid: rawMediaMid != null && validQqMid(rawMediaMid)
        ? rawMediaMid
        : null,
    durationMs: duration != null && duration > 0 ? duration * 1000 : null,
    songType: type < 0 ? 0 : type,
    qualitySizes: qualitySizes,
  );
}

QqTrack parseQqSongDetail(
  Map<String, Object?> data, {
  required String expectedMid,
  int expectedSongId = 0,
}) {
  final track = parseQqTrack(data['track_info']);
  // The requested type is a hint. The detail endpoint can canonicalize it.
  if ((expectedMid.isEmpty && expectedSongId <= 0) ||
      (expectedMid.isNotEmpty && track.mid != expectedMid) ||
      (expectedSongId > 0 && track.songId != expectedSongId)) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  return track;
}

QqSearchPage parseQqSearchPage(
  Map<String, Object?> root,
  int page,
  int pageSize,
) {
  final body = qqObject(root['body']);
  final song = body['song'];
  final Object? raw = song is List
      ? song
      : song is Map
      ? (song['list'] ?? song['items'])
      : null;
  if (raw is! List) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final tracks = <String, QqTrack>{};
  for (final item in raw.take(pageSize)) {
    try {
      final track = parseQqTrack(item);
      tracks.putIfAbsent(track.mid, () => track);
    } on OnlineException {
      // A malformed item must not erase usable siblings or fabricate identity.
    }
  }
  if (raw.isNotEmpty && tracks.isEmpty) {
    throw const OnlineException(OnlineErrorKind.malformedResponse);
  }
  final meta = root['meta'] is Map<String, Object?>
      ? qqObject(root['meta'])
      : const <String, Object?>{};
  final total = qqInt(meta['sum']) ?? qqInt(root['total_num']);
  final next = qqInt(meta['nextpage']);
  return QqSearchPage(
    tracks: tracks.values.toList(),
    page: page,
    total: total != null && total >= 0 ? total : null,
    hasMore:
        raw.isNotEmpty &&
        (next != null
            ? next >= 0
            : total != null && total >= 0
            ? page * pageSize < total
            : raw.length >= pageSize),
  );
}

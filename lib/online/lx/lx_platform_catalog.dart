import 'dart:async';
import 'dart:convert';

import '../../audio/controlled_pcm.dart';
import '../../library/domain/track_normalization.dart';
import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../qq/qq_track.dart';
import 'fixture/lx_fixture_wave.dart';
import 'lx_http_connection.dart';
import 'lx_music_platform.dart';
import 'lx_network.dart';
import 'lx_request_error.dart';

enum LxMatchReason {
  insufficientMetadata,
  noMatch,
  ambiguous,
  missingQuality,
  matched,
}

typedef LxPlatformMatch = ({
  LxMatchReason reason,
  Map<String, Object?>? music,
  bool cached,
});
typedef _Match = ({LxMatchReason reason, _Song? song});

/// Host-owned, anonymous first-page lookups, not a search API for scripts.
/// Cache only bounded public metadata (including misses), never audio URLs.
final class LxPlatformCatalog {
  LxPlatformCatalog({LxWireOpen? open, DateTime Function()? now})
    : _open = open ?? openLxHttps,
      _now = now ?? DateTime.now;
  final LxWireOpen _open;
  final DateTime Function() _now;
  final _cache =
      <(LxPlatform, OnlineQuality, String), ({DateTime until, _Match match})>{};
  final _cooldown = <LxPlatform, DateTime>{};
  static const pageSize = 8;

  Future<LxPlatformMatch> match(
    LxPlatform platform,
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation cancellation,
  ) async {
    cancellation.check();
    const insufficient = (
      reason: LxMatchReason.insufficientMetadata,
      music: null,
      cached: false,
    );
    final title = track.title.trim();
    final artists = track.artists;
    final duration = track.durationMs ?? 0;
    if (platform == LxPlatform.tx ||
        duration <= 0 ||
        !_validText(title) ||
        artists.isEmpty ||
        artists.length > 12 ||
        !artists.every(_validText)) {
      return insufficient;
    }
    final term = '$title ${artists.join('、')}';
    if (term.length > 160 || track.album.length > 256) return insufficient;
    final uri = switch (platform) {
      LxPlatform.kw => Uri.https('search.kuwo.cn', '/r.s', {
        'all': term,
        'pn': '0',
        'rn': '$pageSize',
        'client': 'kt',
        'ver': 'kwplayer_ar_9.2.2.1',
        'vipver': '1',
        'show_copyright_off': '1',
        'newver': '1',
        'ft': 'music',
        'cluster': '0',
        'strategy': '2012',
        'encoding': 'utf8',
        'rformat': 'json',
        'vermerge': '1',
        'mobi': '1',
        'issubtitle': '1',
      }),
      LxPlatform.kg => Uri.https('songsearch.kugou.com', '/song_search_v2', {
        'keyword': term,
        'page': '1',
        'pagesize': '$pageSize',
        'userid': '0',
        'clientver': '',
        'platform': 'WebFilter',
        'filter': '2',
        'iscorrection': '1',
        'privilege_filter': '0',
        'area_code': '1',
      }),
      LxPlatform.tx => throw StateError('QQ uses the original catalog'),
    };
    final key = (
      platform,
      quality,
      jsonEncode([title, artists, track.album, duration]),
    );
    final now = _now();
    if (_cooldown[platform]?.isAfter(now) ?? false) {
      throw const OnlineException(OnlineErrorKind.rateLimited);
    }
    final cached = _cache[key];
    if (cached != null && cached.until.isAfter(now)) {
      return (
        reason: cached.match.reason,
        music: cached.match.song?.musicInfo(),
        cached: true,
      );
    }
    final scope = PcmCancellation();
    final unlink = cancellation.listen(scope.cancel);
    final timer = Timer(lxWireTimeout, scope.cancel);
    LxWireResponse? reply;
    try {
      reply = await _open(
        uri,
        'GET',
        const {'accept': 'application/json', 'user-agent': 'Motif/0.1'},
        null,
        scope,
      );
      scope.check();
      if (reply.status == 429) {
        _cooldown[platform] = _now().add(const Duration(seconds: 30));
        throw const OnlineException(OnlineErrorKind.rateLimited);
      }
      if (reply.status == 401 || reply.status == 403 || reply.status == 407) {
        throw const OnlineException(OnlineErrorKind.rejected);
      }
      if (reply.status != 200) {
        throw const OnlineException(OnlineErrorKind.unavailable);
      }
      final encoding = reply.headers['content-encoding'];
      if (encoding != null &&
          (encoding.length != 1 ||
              encoding.single.toLowerCase() != 'identity')) {
        throw const OnlineException(OnlineErrorKind.malformedResponse);
      }
      final bytes = await readLxResponseBody(reply, 'GET', maximum: 256 * 1024);
      scope.check();
      final rows = _rows(platform, jsonDecode(utf8.decode(bytes)));
      final result = _match(rows, platform, track, quality);
      _cache.remove(key);
      if (_cache.length >= 48) _cache.remove(_cache.keys.first);
      _cache[key] = (
        until: _now().add(Duration(seconds: result.song == null ? 30 : 300)),
        match: result,
      );
      return (
        reason: result.reason,
        music: result.song?.musicInfo(),
        cached: false,
      );
    } on PcmCancelled {
      cancellation.check();
      throw const LxRequestException(LxRequestFailure.timeout);
    } on FormatException {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    } on FixtureMediaException catch (e) {
      throw LxRequestException(
        e.kind == FixtureMediaFailure.denied
            ? LxRequestFailure.privateAddress
            : LxRequestFailure.response,
      );
    } finally {
      timer.cancel();
      reply?.body.close();
      unlink();
      scope.cancel();
    }
  }
}

List<dynamic> _rows(LxPlatform platform, Object? body) {
  const invalid = OnlineException(OnlineErrorKind.malformedResponse);
  if (body is! Map) throw invalid;
  final List rows;
  if (platform == LxPlatform.kw) {
    if (body['TOTAL']?.toString() == '0' || body['SHOW']?.toString() == '0') {
      return const [];
    }
    if (body['abslist'] is! List) throw invalid;
    rows = body['abslist'] as List;
  } else {
    if (body['error_code'] != 0 || body['data'] is! Map) throw invalid;
    final list = body['data']['lists'];
    if (list is! List) throw invalid;
    rows = list;
  }
  if (rows.length > LxPlatformCatalog.pageSize) throw invalid;
  final flat = <dynamic>[];
  for (final row in rows.whereType<Map>()) {
    flat.add(row);
    if ((platform == LxPlatform.kg ? row['Grp'] : null)
        case final List children) {
      if (flat.length + children.length > 64) throw invalid;
      flat.addAll(children);
    }
    if (flat.length > 64) throw invalid;
  }
  return flat;
}

_Match _match(
  List<dynamic> rows,
  LxPlatform platform,
  QqTrack track,
  OnlineQuality quality,
) {
  final title = TrackNormalization.key(track.title);
  final artists = _artistKey(track.artists);
  final album = TrackNormalization.key(track.album);
  final matches = <(String, String?, Object?), _Song>{};
  var missingQuality = false;
  for (final raw in rows.whereType<Map>()) {
    final song = platform == LxPlatform.kw ? _kw(raw) : _kg(raw);
    if (song == null ||
        TrackNormalization.key(song.title) != title ||
        _artistKey(song.artists) != artists ||
        (song.seconds * 1000 - track.durationMs!).abs() > 5000) {
      continue;
    }
    final otherAlbum = TrackNormalization.key(song.album);
    if (album.isNotEmpty && otherAlbum.isNotEmpty && album != otherAlbum) {
      continue;
    }
    final spec = song.types[quality.lxValue];
    if (spec == null) {
      missingQuality = true;
      continue;
    }
    matches[(song.id.toString(), song.hash?.toLowerCase(), spec['hash'])] =
        song;
  }
  final exactAlbum = matches.values.where(
    (s) => album.isNotEmpty && TrackNormalization.key(s.album) == album,
  );
  final best = exactAlbum.isEmpty ? matches.values : exactAlbum;
  if (best.length == 1) {
    return (reason: LxMatchReason.matched, song: best.single);
  }
  return (
    reason: best.isNotEmpty
        ? LxMatchReason.ambiguous
        : missingQuality
        ? LxMatchReason.missingQuality
        : LxMatchReason.noMatch,
    song: null,
  );
}

String _artistKey(List<String> artists) =>
    jsonEncode(artists.map(TrackNormalization.key).toList()..sort());
bool _validText(String s) =>
    s.trim().isNotEmpty &&
    s.length <= 256 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(s);
String _text(Object? value) => value is String && _validText(value)
    ? value
          .trim()
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&apos;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&')
    : '';
int _int(Object? v) => v is int
    ? v
    : v is String
    ? int.tryParse(v) ?? 0
    : 0;
bool _numericId(Object? id) =>
    (id is String || id is int) &&
    RegExp(r'^[1-9]\d{0,17}$').hasMatch(id.toString());
final _hash = RegExp(r'^[0-9a-fA-F]{32}$');
final _kwSpec = RegExp(
  r'level:\w+,bitrate:(128|320|2000|4000),format:\w+,size:(\d+(?:\.\d+)?[kKmMgG]?[bB]?)(?:,|$)',
);

_Song? _kw(Map row) {
  final id = _text(row['MUSICRID']).replaceFirst(RegExp('^MUSIC_'), '');
  final seconds = _int(row['DURATION']);
  if (!_numericId(id) || seconds <= 0 || seconds > 86400) return null;
  final specs = row['N_MINFO'];
  if (specs is! String || specs.length > 4096) return null;
  final types = <String, Map<String, Object?>>{};
  for (final part in specs.split(';')) {
    final match = _kwSpec.firstMatch(part);
    if (match == null || !RegExp(r'[1-9]').hasMatch(match[2]!)) continue;
    final type = const {
      '128': '128k',
      '320': '320k',
      '2000': 'flac',
      '4000': 'flac24bit',
    }[match[1]]!;
    types[type] = {'size': match[2]!.toUpperCase()};
  }
  return _Song(
    LxPlatform.kw,
    id,
    _text(row['SONGNAME']),
    _text(row['ARTIST']).split(RegExp('[&、]')).map((s) => s.trim()).toList(),
    _text(row['ALBUM']),
    _numericId(row['ALBUMID']) ? row['ALBUMID'] : '',
    seconds,
    types,
  );
}

_Song? _kg(Map row) {
  final id = row['Audioid'];
  final hash = row['FileHash'];
  final seconds = _int(row['Duration']);
  final artists = row['Singers'];
  if (!_numericId(id) ||
      hash is! String ||
      !_hash.hasMatch(hash) ||
      artists is! List ||
      artists.isEmpty ||
      artists.length > 12 ||
      seconds <= 0 ||
      seconds > 86400) {
    return null;
  }
  final names = [
    for (final artist in artists)
      if (artist is Map) _text(artist['name']),
  ];
  if (names.length != artists.length || names.any((s) => s.isEmpty)) {
    return null;
  }
  final types = <String, Map<String, Object?>>{};
  for (final (tier, prefix) in const [
    ('128k', ''),
    ('320k', 'HQ'),
    ('flac', 'SQ'),
    ('flac24bit', 'Res'),
  ]) {
    final size = _int(row['${prefix}FileSize']);
    final fileHash = row['${prefix}FileHash'];
    if (size > 0 && fileHash is String && _hash.hasMatch(fileHash)) {
      types[tier] = {'size': lxSize(size), 'hash': fileHash};
    }
  }
  final suffix = _text(row['Suffix']);
  final title = _text(row['OriSongName']);
  if (title.isEmpty ||
      (row['Suffix'] != null && row['Suffix'] != '' && suffix.isEmpty)) {
    return null;
  }
  return _Song(
    LxPlatform.kg,
    id,
    suffix.isEmpty ? title : '$title $suffix',
    names,
    _text(row['AlbumName']),
    _numericId(row['AlbumID']) ? row['AlbumID'] : '',
    seconds,
    types,
    hash: hash,
  );
}

final class _Song {
  _Song(
    this.platform,
    this.id,
    this.title,
    this.artists,
    this.album,
    this.albumId,
    this.seconds,
    this.types, {
    this.hash,
  });
  final LxPlatform platform;
  final Object id, albumId;
  final String title, album;
  final String? hash;
  final List<String> artists;
  final int seconds;
  final Map<String, Map<String, Object?>> types;
  Map<String, Object?> musicInfo() => {
    'source': platform.name,
    'songmid': id,
    'name': title,
    'singer': artists.join('、'),
    'albumName': album,
    'albumId': albumId,
    'interval': lxInterval(seconds),
    'img': '',
    if (hash != null) 'hash': hash,
    'types': [
      for (final q in OnlineQuality.values)
        if (types[q.lxValue] case final spec?) {'type': q.lxValue, ...spec},
    ],
    '_types': {
      for (final e in types.entries) e.key: {...e.value},
    },
    'typeUrl': <String, Object?>{},
  };
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../network/qq_http_transport.dart';
import '../network/request_coordinator.dart';
import 'qq_response_parser.dart';
import 'qq_track.dart';
import 'qq_account_api.dart';
import 'auth/qq_session_manager.dart';

/// Anonymous QQ catalog and playback API. No fallback searches, tier probes,
/// parallel ticket requests, account cookies, or automatic retries.
class QqMusicClient implements PlaybackUrlResolver {
  QqMusicClient({
    QqHttpTransport? transport,
    RequestCoordinator? coordinator,
    DateTime Function()? now,
    String? guid,
    this.accountApi,
  }) : _transport = transport ?? IoQqHttpTransport(),
       _coordinator = coordinator ?? RequestCoordinator(now: now),
       _now = now ?? DateTime.now,
       _guid = guid ?? _newGuid() {
    if (!RegExp(r'^\d{10}$').hasMatch(_guid)) {
      throw ArgumentError('Invalid GUID');
    }
  }

  final QqHttpTransport _transport;
  final RequestCoordinator _coordinator;
  final DateTime Function() _now;
  final String _guid;
  final QqAccountApi? accountApi;
  @override
  String get sourceId => 'qq';
  static final _musicUri = Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg');

  Future<QqSearchPage> search(String query, {int page = 1, int pageSize = 30}) {
    final text = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty ||
        text.length > 200 ||
        page < 1 ||
        page > 100 ||
        pageSize < 1 ||
        pageSize > 30) {
      throw ArgumentError('Invalid search parameters');
    }
    return _coordinator.run(
      jsonEncode(['search', text, page, pageSize]),
      ttl: const Duration(minutes: 10),
      request: () async {
        final root = await _json(
          QqHttpRequest(
            uri: _musicUri,
            userAgent: 'QQMusic 20050009(android 14)',
            jsonBody: {
              'comm': {
                'ct': 19,
                'cv': 1859,
                'v': 1859,
                'uin': '0',
                'qq': '0',
                'authst': '',
                'chid': '10003505',
                'tmeAppID': 'qqmusic',
                'tmeLoginType': 2,
                'format': 'json',
              },
              'SONG': {
                'module': 'music.search.SearchCgiService',
                'method': 'DoSearchForQQMusicDesktop',
                'param': {
                  'query': text,
                  'search_type': 0,
                  'page_num': page,
                  'num_per_page': pageSize,
                  'sin': (page - 1) * pageSize,
                  'ein': page * pageSize,
                  'highlight': 0,
                  'cat': 2,
                  'grp': 1,
                  'nqc_flag': 0,
                  'remoteplace': 'txt.mqq.all',
                  'multi_zhida': 0,
                  'sem': 0,
                },
              },
            },
          ),
        );
        final song = qqObject(root['SONG']);
        _checkCode(song);
        final data = qqObject(song['data']);
        if ((qqInt(data['code']) ?? 0) != 0 ||
            (data['meta'] is Map &&
                (qqInt((data['meta'] as Map)['is_filter']) ?? 0) < 0)) {
          throw const OnlineException(OnlineErrorKind.rejected);
        }
        return parseQqSearchPage(data, page, pageSize);
      },
    );
  }

  Future<QqTrack> detail(String mid, {int songType = 0}) {
    if (!validQqMid(mid) || songType < 0) {
      throw ArgumentError('Invalid song identity');
    }
    return _coordinator.run(
      jsonEncode(['detail', mid, songType]),
      ttl: const Duration(hours: 24),
      request: () async {
        final data = await _module(
          'music.pf_song_detail_svr',
          'get_song_detail_yqq',
          {'song_mid': mid, 'song_type': songType},
        );
        final track = parseQqTrack(data['track_info']);
        if (track.mid != mid || track.songType != songType) {
          throw const OnlineException(OnlineErrorKind.malformedResponse);
        }
        return track;
      },
    );
  }

  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) {
    if (!validQqMid(track.mid) ||
        track.songType < 0 ||
        (track.mediaMid != null && !validQqMid(track.mediaMid!))) {
      throw ArgumentError('Invalid song identity');
    }
    if (accountApi?.sessions.snapshot.credential != null) {
      return accountApi!.resolve(track, quality);
    }
    if (accountApi?.sessions.status == QqSessionStatus.expired) {
      return Future.error(
        const OnlineException(OnlineErrorKind.sessionExpired),
      );
    }
    return _coordinator.run(
      jsonEncode([
        'url',
        track.mid,
        track.mediaMid,
        track.songType,
        quality.name,
      ]),
      ttl: const Duration(seconds: 30),
      request: () async {
        final (prefix, extension) = switch (quality) {
          OnlineQuality.standard => ('M500', 'mp3'),
          OnlineQuality.high => ('M800', 'mp3'),
          OnlineQuality.lossless => ('F000', 'flac'),
          OnlineQuality.hiRes => ('RS01', 'flac'),
        };
        final filename =
            '$prefix${track.mediaMid ?? '${track.mid}${track.mid}'}.$extension';
        final data = await _module('music.vkey.GetVkey', 'UrlGetVkey', {
          'guid': _guid,
          'songmid': [track.mid],
          'songtype': [track.songType],
          'uin': '0',
          'loginflag': 1,
          'platform': '23',
          'h5queryversion': 1,
          'nettype': '',
          'cms': 0,
          'firstlogin': 1,
          'newver': 1,
          'nohash': 0,
          'quality': prefix,
          'filename': [filename],
        });
        final entries = data['midurlinfo'];
        if (entries is! List || entries.isEmpty) {
          throw const OnlineException(OnlineErrorKind.unavailable);
        }
        Uri? selected;
        for (final item in entries.take(10)) {
          if (item is! Map<String, Object?>) continue;
          if (qqInt(item['result']) != 0) continue;
          if (item['songmid'] != null && item['songmid'] != track.mid) continue;
          final purl = qqText(item['purl']);
          if (purl == null) continue;
          final relative = Uri.tryParse(purl);
          if (relative == null ||
              relative.pathSegments.isEmpty ||
              relative.pathSegments.last != filename) {
            continue;
          }
          if (relative.hasScheme) {
            selected = parsePlaybackUri(purl);
          } else if (data['sip'] case final List servers) {
            final bases =
                servers
                    .whereType<String>()
                    .map(parsePlaybackUri)
                    .whereType<Uri>()
                    .toList()
                  ..sort(
                    (a, b) => (a.scheme == 'https' ? 0 : 1).compareTo(
                      b.scheme == 'https' ? 0 : 1,
                    ),
                  );
            for (final base in bases.take(10)) {
              selected = parsePlaybackUri(base.resolve(purl).toString());
              if (selected != null) break;
            }
          }
          if (selected != null) break;
        }
        if (selected == null) {
          throw const OnlineException(OnlineErrorKind.unavailable);
        }
        return OnlineStream(
          uri: selected,
          sourceId: sourceId,
          requestedQuality: quality,
        );
      },
    );
  }

  Future<Map<String, Object?>> _module(
    String module,
    String method,
    Map<String, Object?> params,
  ) async {
    final root = await _json(
      QqHttpRequest(
        uri: _musicUri,
        jsonBody: {
          'comm': {
            'ct': 24,
            'cv': 4747474,
            'format': 'json',
            'inCharset': 'utf-8',
            'outCharset': 'utf-8',
            'platform': 'yqq.json',
            'needNewCode': 1,
            'uin': '0',
          },
          'req_1': {'module': module, 'method': method, 'param': params},
        },
      ),
    );
    final item = qqObject(root['req_1']);
    _checkCode(item);
    return qqObject(item['data']);
  }

  Future<Map<String, Object?>> _json(QqHttpRequest request) async {
    final response = await _transport.send(request);
    if (response.statusCode == 429 || response.statusCode == 503) {
      throw OnlineException(
        OnlineErrorKind.rateLimited,
        retryAt: _retryAt(response.retryAfter),
      );
    }
    if ({401, 403}.contains(response.statusCode) ||
        response.statusCode >= 300 && response.statusCode < 400) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    if (response.statusCode != 200) {
      throw const OnlineException(OnlineErrorKind.transport);
    }
    if (response.body.trimLeft().startsWith('<')) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    Map<String, Object?> root;
    try {
      root = qqObject(jsonDecode(response.body));
    } on FormatException {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    _checkCode(root);
    return root;
  }

  void _checkCode(Map<String, Object?> value) {
    final code = qqInt(value['code']);
    if (code == null) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    if (code != 0) throw const OnlineException(OnlineErrorKind.rejected);
  }

  DateTime? _retryAt(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null && seconds >= 0 && seconds <= 31536000) {
      return _now().add(Duration(seconds: seconds));
    }
    try {
      return HttpDate.parse(header);
    } on FormatException {
      return null;
    }
  }

  @override
  void close() {
    _coordinator.close();
    _transport.close();
  }

  static String _newGuid() {
    final random = Random.secure();
    return '${random.nextInt(9) + 1}${List.generate(9, (_) => random.nextInt(10)).join()}';
  }
}

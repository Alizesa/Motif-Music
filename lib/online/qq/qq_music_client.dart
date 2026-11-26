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
import 'auth/qq_login_protocol.dart';
import 'qq_request_protocol.dart';

/// QQ catalog and playback, with signed operations delegated to the account
/// API. The public transport never receives account cookies.
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
    final text = qqSearchQuery(query, page: page, pageSize: pageSize);
    if (accountApi?.sessions.snapshot.credential != null) {
      return accountApi!.search(text, page: page, pageSize: pageSize);
    }
    return _coordinator.run(
      jsonEncode(['search', text, page, pageSize]),
      ttl: const Duration(minutes: 10),
      request: () async {
        final root = await _json(
          QqHttpRequest(
            uri: _musicUri,
            userAgent: qqSearchUserAgent,
            jsonBody: {
              'comm': qqSearchComm(),
              'SONG': {
                'module': 'music.search.SearchCgiService',
                'method': 'DoSearchForQQMusicDesktop',
                'param': qqSearchParameters(text, page, pageSize),
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
    if (accountApi?.sessions.snapshot.credential != null) {
      return accountApi!.detail(mid, songType: songType);
    }
    return publicDetail(mid, songType: songType);
  }

  /// Catalog metadata only. Downloads must not use account cookies or tickets.
  Future<QqTrack> publicDetail(String mid, {int songType = 0}) {
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
          {'song_mid': mid, 'song_type': songType, 'song_id': 0},
        );
        return parseQqSongDetail(data, expectedMid: mid);
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
        final data = await _module(
          'music.vkey.GetVkey',
          'UrlGetVkey',
          qqPlaybackParameters(track, quality, guid: _guid, accountId: '0'),
          mobile: true,
        );
        final selected = qqPlaybackUri(data, track, quality);
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
    Map<String, Object?> params, {
    bool mobile = false,
  }) async {
    final root = await _json(
      QqHttpRequest(
        uri: _musicUri,
        userAgent: mobile ? qqMusicUserAgent : qqWebUserAgent,
        origin: mobile ? null : 'https://y.qq.com',
        jsonBody: {
          'comm': mobile ? qqPlaybackComm(null) : qqWebComm(),
          'req_1': {'module': module, 'method': method, 'param': params},
        },
      ),
    );
    final item = qqObject(root['req_1']);
    _checkCode(item);
    final data = qqObject(item['data']);
    if (mobile && data['midurlinfo'] is List) {
      for (final row in (data['midurlinfo'] as List).take(10)) {
        if (row is Map && qqBlockingVkeyCodes.contains(qqInt(row['result']))) {
          _checkCode({'code': row['result']});
        }
      }
    }
    return data;
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
    if (qqBusinessRateLimitCodes.contains(code)) {
      throw const OnlineException(OnlineErrorKind.rateLimited);
    }
    if (qqCredentialExpiredCodes.contains(code)) {
      throw const OnlineException(OnlineErrorKind.authenticationRequired);
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

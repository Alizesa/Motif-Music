import 'dart:async';
import 'dart:convert';

import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../network/qq_account_transport.dart';
import '../network/request_coordinator.dart';
import 'auth/qq_auth_client.dart';
import 'auth/qq_auth_error.dart';
import 'auth/qq_credential.dart';
import 'auth/qq_login_protocol.dart';
import 'auth/qq_session_manager.dart';
import 'qq_home_models.dart';
import 'qq_home_parser.dart';
import 'qq_response_parser.dart';
import 'qq_track.dart';
import 'qq_request_protocol.dart';

enum _Comm { playback, personalized, playlist, search, web }

/// Authenticated QQ catalog/recommendation operations share one bounded queue.
/// A captured epoch owns every cache entry and every response publication.
class QqAccountApi {
  QqAccountApi({
    required this.sessions,
    QqAccountTransport? transport,
    RequestCoordinator? coordinator,
    this._renewClient,
    DateTime Function()? now,
  }) : _transport = transport ?? IoQqAccountTransport(),
       _coordinator = coordinator ?? RequestCoordinator(),
       _now = now ?? DateTime.now {
    _epoch = sessions.epoch;
    _subscription = sessions.changes.listen((_) {
      if (sessions.epoch != _epoch) {
        _epoch = sessions.epoch;
        _verifiedCookie = '';
        _coordinator.invalidate(
          reason: sessions.status == QqSessionStatus.expired
              ? OnlineErrorKind.sessionExpired
              : OnlineErrorKind.sessionChanged,
        );
      }
    });
  }
  final QqSessionManager sessions;
  final QqAccountTransport _transport;
  final RequestCoordinator _coordinator;
  final QqAuthClient? _renewClient;
  final DateTime Function() _now;
  late final StreamSubscription<QqSessionStatus> _subscription;
  late int _epoch;
  bool _closed = false;
  String _verifiedCookie = '';
  int _radioSequence = 0;
  int _verificationSequence = 0;
  Future<void>? _renewing;
  int? _renewingEpoch;
  DateTime? _renewFailedAt;
  int? _renewFailedEpoch;
  QqVerify? verify;

  void _active(QqSessionSnapshot value) {
    if (_closed) throw const OnlineException(OnlineErrorKind.closed);
    if (!sessions.isCurrent(value)) {
      throw const OnlineException(OnlineErrorKind.sessionChanged);
    }
  }

  Future<QqSessionSnapshot> _prepare() async {
    await sessions.initialize();
    var snapshot = sessions.snapshot;
    if (snapshot.credential == null) {
      throw const OnlineException(OnlineErrorKind.authenticationRequired);
    }
    final expires = snapshot.credential!.expiresAt;
    if (_renewClient != null &&
        expires != null &&
        expires.isBefore(_now().add(const Duration(minutes: 5)))) {
      final blocked =
          _renewFailedEpoch == snapshot.epoch &&
          _renewFailedAt != null &&
          _now().difference(_renewFailedAt!) < const Duration(minutes: 1);
      if (!blocked) {
        if (_renewing == null || _renewingEpoch != snapshot.epoch) {
          _renewingEpoch = snapshot.epoch;
          _renewing = Future<void>.microtask(() => _renew(snapshot));
        }
        await _renewing;
      }
      snapshot = sessions.snapshot;
    }
    if (snapshot.credential == null) {
      throw const OnlineException(OnlineErrorKind.sessionExpired);
    }
    _active(snapshot);
    return snapshot;
  }

  Future<void> _renew(QqSessionSnapshot previous) async {
    try {
      final credential = await _renewClient!.refresh(
        previous.credential!,
        sessions.deviceId,
        isActive: () => !_closed && sessions.isCurrent(previous),
      );
      if (sessions.isCurrent(previous)) {
        await sessions.renew(previous, credential);
      }
      _renewFailedEpoch = null;
      _renewFailedAt = null;
    } on QqAuthException catch (error) {
      if (sessions.isCurrent(previous)) {
        _renewFailedEpoch = previous.epoch;
        _renewFailedAt = _now();
        if ({
          QqAuthErrorKind.expired,
          QqAuthErrorKind.rejected,
          QqAuthErrorKind.disabled,
        }.contains(error.kind)) {
          await sessions.reject(previous);
        }
      }
    } finally {
      if (_renewingEpoch == previous.epoch) {
        _renewing = null;
        _renewingEpoch = null;
      }
    }
  }

  Future<Map<String, Object?>> _call(
    String key,
    String module,
    String method,
    Map<String, Object?> params, {
    String requestKey = 'req_0',
    _Comm comm = _Comm.playback,
    Duration ttl = const Duration(minutes: 5),
    QqSessionSnapshot? captured,
  }) async {
    final snapshot = captured ?? await _prepare();
    _active(snapshot);
    if (snapshot.credential == null) {
      throw const OnlineException(OnlineErrorKind.authenticationRequired);
    }
    final cacheKey = jsonEncode([
      snapshot.epoch,
      _verificationSequence,
      key,
      params,
    ]);
    final first = await _coordinator.run<_RpcOutcome>(
      cacheKey,
      ttl: ttl,
      request: () => _post(snapshot, module, method, params, requestKey, comm),
    );
    _active(snapshot);
    if (first.challenge == null) return first.data!;
    final verifier = verify;
    if (verifier == null) throw const OnlineException(OnlineErrorKind.rejected);
    final result = await verifier(first.challenge!);
    _active(snapshot);
    if (result == null) {
      throw const OnlineException(OnlineErrorKind.sessionChanged);
    }
    final cookie = mergeQqCookies(first.challenge!.cookie, result.cookie);
    if (accountIdFromCookies(qqCookieValues(cookie)) !=
        snapshot.credential!.accountId) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    final verified = await _coordinator.run<_RpcOutcome>(
      jsonEncode([snapshot.epoch, key, 'verified', ++_verificationSequence]),
      ttl: Duration.zero,
      request: () => _post(
        snapshot,
        module,
        method,
        params,
        requestKey,
        comm,
        cookie: cookie,
      ),
    );
    _active(snapshot);
    if (verified.challenge != null) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    _verifiedCookie = cookie;
    return verified.data!;
  }

  Future<_RpcOutcome> _post(
    QqSessionSnapshot snapshot,
    String module,
    String method,
    Map<String, Object?> params,
    String requestKey,
    _Comm comm, {
    String? cookie,
  }) async {
    _active(snapshot);
    final credential = snapshot.credential!;
    final header = switch (comm) {
      _Comm.personalized => qqPersonalizedComm(credential),
      _Comm.search => qqSearchComm(credential),
      _Comm.web => qqWebComm(credential),
      _Comm.playback || _Comm.playlist => qqPlaybackComm(credential),
    };
    final userAgent = switch (comm) {
      _Comm.personalized || _Comm.web => qqWebUserAgent,
      _Comm.search => qqSearchUserAgent,
      _Comm.playlist => qqPlaylistUserAgent,
      _Comm.playback => qqMusicUserAgent,
    };
    if (comm == _Comm.playlist) {
      header['ct'] = 19;
      header['cv'] = 0;
      header.remove('v');
    }
    final sentCookie =
        cookie ?? mergeQqCookies(credential.cookie, _verifiedCookie);
    QqAccountResponse response;
    try {
      response = await _transport.send(
        QqAccountRequest(
          uri: Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
          userAgent: userAgent,
          origin: comm == _Comm.web || comm == _Comm.personalized
              ? 'https://y.qq.com'
              : null,
          cookie: sentCookie,
          jsonBody: {
            'comm': header,
            requestKey: {'module': module, 'method': method, 'param': params},
          },
        ),
      );
    } on QqAuthException catch (error) {
      throw OnlineException(
        error.kind == QqAuthErrorKind.rateLimited
            ? OnlineErrorKind.rateLimited
            : OnlineErrorKind.transport,
      );
    }
    _active(snapshot);
    if (response.status == 429 || response.status == 503) {
      throw const OnlineException(OnlineErrorKind.rateLimited);
    }
    if (response.status == 401) {
      await sessions.reject(snapshot);
      throw const OnlineException(OnlineErrorKind.sessionExpired);
    }
    if (response.status == 403 ||
        response.status >= 300 && response.status < 400) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    if (response.status != 200) {
      throw const OnlineException(OnlineErrorKind.transport);
    }
    Map<String, Object?> root;
    try {
      root = qqObject(jsonDecode(response.text));
    } on FormatException {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    _active(snapshot);
    final merged = mergeQqCookies(sentCookie, response.cookie);
    final topFailure = await _businessFailure(root, snapshot, merged);
    if (topFailure != null) return topFailure;
    final sub = qqObject(root[requestKey]);
    final subFailure = await _businessFailure(sub, snapshot, merged);
    if (subFailure != null) return subFailure;
    final data = qqObject(sub['data']);
    for (final field in ['code', 'subcode']) {
      final failure = await _businessFailure(
        data,
        snapshot,
        merged,
        field: field,
        optional: true,
      );
      if (failure != null) return failure;
    }
    if (module == 'music.vkey.GetVkey' && data['midurlinfo'] is List) {
      for (final item in (data['midurlinfo'] as List).take(10)) {
        if (item is! Map<String, Object?> ||
            !qqBlockingVkeyCodes.contains(qqInt(item['result']))) {
          continue;
        }
        final failure = await _businessFailure(
          item,
          snapshot,
          merged,
          field: 'result',
          verificationFallback: data,
        );
        if (failure != null) return failure;
      }
    }
    return _RpcOutcome.data(data);
  }

  Future<_RpcOutcome?> _businessFailure(
    Map<String, Object?> value,
    QqSessionSnapshot snapshot,
    String cookie, {
    String field = 'code',
    bool optional = false,
    Map<String, Object?>? verificationFallback,
  }) async {
    final code = qqInt(value[field]);
    if (code == null) {
      if (optional) return null;
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    if (code == 0) return null;
    final challenge =
        qqRequestSecurityChallenge(value, cookie, code: code) ??
        (verificationFallback == null
            ? null
            : qqRequestSecurityChallenge(
                verificationFallback,
                cookie,
                code: code,
              ));
    if (challenge != null) return _RpcOutcome.challenge(challenge);
    if (qqCredentialExpiredCodes.contains(code)) {
      await sessions.reject(snapshot);
      throw const OnlineException(OnlineErrorKind.sessionExpired);
    }
    if (qqBusinessRateLimitCodes.contains(code)) {
      throw const OnlineException(OnlineErrorKind.rateLimited);
    }
    throw const OnlineException(OnlineErrorKind.rejected);
  }

  Future<QqSearchPage> search(
    String query, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final text = qqSearchQuery(query, page: page, pageSize: pageSize);
    final data = await _call(
      'search:$text:$page:$pageSize',
      'music.search.SearchCgiService',
      'DoSearchForQQMusicDesktop',
      qqSearchParameters(text, page, pageSize),
      requestKey: 'SONG',
      comm: _Comm.search,
      ttl: const Duration(minutes: 10),
    );
    if (data['meta'] is Map &&
        (qqInt((data['meta'] as Map)['is_filter']) ?? 0) < 0) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    return parseQqSearchPage(data, page, pageSize);
  }

  Future<List<QqTrack>> daily() async {
    final snapshot = await _prepare();
    final credential = snapshot.credential!;
    final data = await _call(
      'daily',
      'music.srfDissInfo.DissInfo',
      'CgiGetDiss',
      {
        'new_format': 1,
        'enc_host_uin':
            qqText(credential.values['encryptUin']) ??
            qqText(credential.values['encrypt_uin']) ??
            credential.accountId,
        'dirid': 202,
        'onlysonglist': 1,
        'optype': 0,
        'orderlist': 0,
        'guid': qqStableGuid(sessions.deviceId),
        'is_mobile': 1,
        'local_time': _now().millisecondsSinceEpoch ~/ 1000,
        'update_rtime': 0,
      },
      captured: snapshot,
    );
    return parseQqTrackList(data['songlist'], limit: 30);
  }

  Future<List<QqTrack>> radio({QqSessionSnapshot? session}) async {
    final data = await _call(
      'radio:${++_radioSequence}',
      'music.radioProxy.MbTrackRadioSvr',
      'get_radio_track',
      {'id': 99, 'num': 20, 'from': 0, 'scene': 0, 'song_ids': <int>[]},
      requestKey: 'songlist',
      comm: _Comm.personalized,
      ttl: Duration.zero,
      captured: session,
    );
    return parseQqTrackList(data['tracks'] ?? data['track_list'], limit: 20);
  }

  Future<List<QqPlaylist>> personalizedPlaylists({int page = 0}) async {
    if (page < 0 || page > 10) {
      throw ArgumentError('Invalid recommendation page');
    }
    final data = await _call(
      'playlists:$page',
      'music.playlist.PlaylistSquare',
      'GetRecommendFeed',
      {'From': page * 8, 'Size': 8},
    );
    return parseQqPersonalizedPlaylists(data).take(8).toList();
  }

  Future<List<QqPlaylist>> recentPlaylists() async {
    final data = await _call(
      'recent-folders',
      'music.musicasset.PlayRecentlyRead',
      'GetPlayRecentlyInfo',
      {'type': 4, 'updateTime': 0, 'requestCnt': 500},
      requestKey: 'req_1',
    );
    return parseQqRecentPlaylists(data);
  }

  Future<QqHomeFeed> homeFeed({QqHomeFeed? previous}) async {
    final page = (previous?.page ?? 0) + 1;
    if (page > 10) throw ArgumentError('Invalid feed page');
    final data = await _call(
      'feed:$page',
      'music.recommend.RecommendFeed',
      'get_recommend_feed',
      {
        'direction': page == 1 ? 0 : 1,
        'page': page,
        's_num': previous?.shelfCount ?? 0,
        'client_time': _now().millisecondsSinceEpoch ~/ 1000,
        'v_cache': previous?.shelfIds ?? <String>[],
        if (page > 1) 'v_uniq': previous?.uniqueKeys ?? <String>[],
        'ext': {
          'bluetooth': '0',
          'has_login': '1',
          'no_need_sound_quality': '1',
          'ifRadarBlock': '0',
          'nopack_people': '0',
          'auto_folding_time': '0',
          'first_req_time': page == 1 ? '1' : '0',
          'is_20_style': '1',
          'client_time_zone': 'Asia/Shanghai',
        },
      },
    );
    final parsed = parseQqHomeFeed(data, page: page);
    final keys = <String>{
      ...?previous?.uniqueKeys,
      ...parsed.uniqueKeys,
    }.toList();
    return QqHomeFeed(
      shelves: parsed.shelves,
      playlists: parsed.playlists,
      shelfIds: <String>{
        ...?previous?.shelfIds,
        ...parsed.shelfIds,
      }.take(100).toList(),
      uniqueKeys: keys.skip((keys.length - 100).clamp(0, keys.length)).toList(),
      shelfCount: (previous?.shelfCount ?? 0) + parsed.shelfCount,
      page: page,
      hasMore: parsed.hasMore && page < 10,
    );
  }

  Future<QqPlaylistPage> playlistPage(
    QqPlaylist playlist, {
    int offset = 0,
    int size = 50,
  }) async {
    if (offset < 0 ||
        offset > 10000 ||
        size < 1 ||
        size > 100 ||
        (int.tryParse(playlist.id) ?? 0) <= 0) {
      throw ArgumentError('Invalid playlist page');
    }
    final data = await _call(
      'playlist:${playlist.id}:$offset:$size',
      'music.srfDissInfo.DissInfo',
      'CgiGetDiss',
      {
        'disstid': int.parse(playlist.id),
        'dirid': 0,
        'song_begin': offset,
        'song_num': size,
        'tag': true,
        'userinfo': true,
        'orderlist': true,
        'onlysonglist': false,
      },
      requestKey: 'playlist',
      comm: _Comm.playlist,
    );
    final raw = data['songlist'];
    final tracks = parseQqTrackList(raw, limit: size);
    final total = qqInt(data['total_song_num']);
    final explicit = qqInt(data['hasmore']);
    return QqPlaylistPage(
      tracks: tracks,
      offset: offset,
      total: total,
      hasMore:
          raw is List &&
          raw.isNotEmpty &&
          (explicit != null
              ? explicit != 0
              : total != null
              ? offset + raw.length < total
              : raw.length >= size),
    );
  }

  Future<QqTrack> songDetail(QqRecommendedSong reference) async {
    if (reference.track != null && reference.track!.mediaMid != null) {
      return reference.track!;
    }
    return _songDetail(
      mid: reference.track?.mid ?? '',
      songType: reference.track?.songType ?? 0,
      songId: reference.songId ?? 0,
    );
  }

  Future<QqTrack> detail(String mid, {int songType = 0}) {
    if (!validQqMid(mid) || songType < 0) {
      throw ArgumentError('Invalid song identity');
    }
    return _songDetail(mid: mid, songType: songType, songId: 0);
  }

  Future<QqTrack> _songDetail({
    required String mid,
    required int songType,
    required int songId,
  }) async {
    final data = await _call(
      'song-detail:$mid:$songType:$songId',
      'music.pf_song_detail_svr',
      'get_song_detail_yqq',
      {'song_mid': mid, 'song_type': songType, 'song_id': songId},
      requestKey: 'req_1',
      comm: _Comm.web,
      ttl: const Duration(hours: 1),
    );
    final track = parseQqTrack(data['track_info']);
    if (songId > 0 && track.songId != songId) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    if (mid.isNotEmpty && track.mid != mid || track.songType != songType) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    return track;
  }

  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) async {
    if (!validQqMid(track.mid) ||
        track.songType < 0 ||
        (track.mediaMid != null && !validQqMid(track.mediaMid!))) {
      throw ArgumentError('Invalid song identity');
    }
    final snapshot = await _prepare();
    final data = await _call(
      'url:${track.identity}:${quality.name}',
      'music.vkey.GetVkey',
      'UrlGetVkey',
      qqPlaybackParameters(
        track,
        quality,
        guid: qqStableGuid(sessions.deviceId),
        accountId: snapshot.credential!.accountId,
      ),
      requestKey: 'req_1',
      ttl: const Duration(seconds: 30),
      captured: snapshot,
    );
    final uri = qqPlaybackUri(data, track, quality);
    if (uri == null) {
      throw const OnlineException(OnlineErrorKind.unavailable);
    }
    return OnlineStream(uri: uri, sourceId: 'qq', requestedQuality: quality);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_subscription.cancel());
    _coordinator.close();
    _transport.close();
  }
}

class _RpcOutcome {
  const _RpcOutcome.data(this.data) : challenge = null;
  const _RpcOutcome.challenge(this.challenge) : data = null;
  final Map<String, Object?>? data;
  final QqSecurityChallenge? challenge;
}

String qqStableGuid(String deviceId) {
  var hash = BigInt.parse('1125899906842597');
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final value in deviceId.codeUnits) {
    hash = ((hash ^ BigInt.from(value)) * BigInt.parse('1099511628211')) & mask;
  }
  final positive = hash & ((BigInt.one << 63) - BigInt.one);
  return ((positive % BigInt.from(9000000000)) + BigInt.from(1000000000))
      .toString();
}

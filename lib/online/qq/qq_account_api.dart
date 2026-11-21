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

enum _Comm { playback, personalized, playlist }

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
        _coordinator.invalidate();
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
    final cacheKey = jsonEncode([snapshot.epoch, key, params]);
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
    final header = comm == _Comm.personalized
        ? qqPersonalizedComm(credential)
        : qqPlaybackComm(credential);
    if (comm == _Comm.playlist) {
      header['ct'] = 19;
      header['cv'] = 0;
      header.remove('v');
    }
    QqAccountResponse response;
    try {
      response = await _transport.send(
        QqAccountRequest(
          uri: Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
          cookie: cookie ?? mergeQqCookies(credential.cookie, _verifiedCookie),
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
    final merged = mergeQqCookies(cookie ?? credential.cookie, response.cookie);
    for (final item in [root]) {
      final code = qqInt(item['code']);
      if (code == null) {
        throw const OnlineException(OnlineErrorKind.malformedResponse);
      }
      if ({301, 1000, 104400, 104401}.contains(code)) {
        await sessions.reject(snapshot);
        throw const OnlineException(OnlineErrorKind.sessionExpired);
      }
      if (code == 20276) {
        try {
          checkQqLoginResult(item, merged);
        } on QqVerificationRequired catch (error) {
          return _RpcOutcome.challenge(error.challenge);
        } on QqAuthException {
          throw const OnlineException(OnlineErrorKind.rejected);
        }
      }
      if (code != 0) throw const OnlineException(OnlineErrorKind.rejected);
    }
    final sub = qqObject(root[requestKey]);
    final subCode = qqInt(sub['code']);
    if (subCode == null) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    if ({301, 1000, 104400, 104401}.contains(subCode)) {
      await sessions.reject(snapshot);
      throw const OnlineException(OnlineErrorKind.sessionExpired);
    }
    if (subCode == 20276) {
      try {
        checkQqLoginResult(sub, merged);
      } on QqVerificationRequired catch (error) {
        return _RpcOutcome.challenge(error.challenge);
      } on QqAuthException {
        throw const OnlineException(OnlineErrorKind.rejected);
      }
    }
    if (subCode != 0) throw const OnlineException(OnlineErrorKind.rejected);
    final data = qqObject(qqObject(root[requestKey])['data']);
    if ((qqInt(data['code']) ?? 0) != 0 || (qqInt(data['subcode']) ?? 0) != 0) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    return _RpcOutcome.data(data);
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
        'enc_host_uin': credential.values['encryptUin'] ?? credential.accountId,
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
    final data = await _call(
      'song-detail:${reference.identity}',
      'music.pf_song_detail_svr',
      'get_song_detail_yqq',
      {
        'song_mid': reference.track?.mid ?? '',
        'song_type': reference.track?.songType ?? 0,
        'song_id': reference.songId ?? 0,
      },
      requestKey: 'req_1',
      ttl: const Duration(hours: 1),
    );
    final track = parseQqTrack(data['track_info']);
    if (reference.songId != null && track.songId != reference.songId) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    if (reference.track != null && track.mid != reference.track!.mid) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    return track;
  }

  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) async {
    final snapshot = await _prepare();
    final (prefix, extension) = switch (quality) {
      OnlineQuality.standard => ('M500', 'mp3'),
      OnlineQuality.high => ('M800', 'mp3'),
      OnlineQuality.lossless => ('F000', 'flac'),
      OnlineQuality.hiRes => ('RS01', 'flac'),
    };
    final filename =
        '$prefix${track.mediaMid ?? '${track.mid}${track.mid}'}.$extension';
    final data = await _call(
      'url:${track.identity}:${quality.name}',
      'music.vkey.GetVkey',
      'UrlGetVkey',
      {
        'guid': qqStableGuid(sessions.deviceId),
        'songmid': [track.mid],
        'songtype': [track.songType],
        'uin': snapshot.credential!.accountId,
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
      },
      requestKey: 'req_1',
      ttl: const Duration(seconds: 30),
      captured: snapshot,
    );
    final entries = data['midurlinfo'];
    if (entries is! List) {
      throw const OnlineException(OnlineErrorKind.unavailable);
    }
    for (final raw in entries.take(10)) {
      if (raw is! Map ||
          qqInt(raw['result']) != 0 ||
          raw['songmid'] != null && raw['songmid'] != track.mid) {
        continue;
      }
      final value = qqText(raw['purl']);
      final uri = value == null ? null : Uri.tryParse(value);
      if (uri == null || uri.pathSegments.lastOrNull != filename) continue;
      if (uri.hasScheme) {
        final direct = parsePlaybackUri(value);
        if (direct != null) {
          return OnlineStream(
            uri: direct,
            sourceId: 'qq',
            requestedQuality: quality,
          );
        }
      } else if (data['sip'] is List) {
        final servers =
            (data['sip'] as List)
                .map(parsePlaybackUri)
                .whereType<Uri>()
                .toList()
              ..sort(
                (a, b) => (a.scheme == 'https' ? 0 : 1).compareTo(
                  b.scheme == 'https' ? 0 : 1,
                ),
              );
        for (final server in servers.take(10)) {
          final playable = parsePlaybackUri(server.resolve(value!).toString());
          if (playable != null) {
            return OnlineStream(
              uri: playable,
              sourceId: 'qq',
              requestedQuality: quality,
            );
          }
        }
      }
    }
    throw const OnlineException(OnlineErrorKind.unavailable);
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

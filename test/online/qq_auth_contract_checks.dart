import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/network/qq_account_transport.dart';
import 'package:motif/online/qq/auth/qq_auth_client.dart';
import 'package:motif/online/qq/auth/qq_auth_error.dart';
import 'package:motif/online/qq/auth/qq_credential.dart';
import 'package:motif/online/qq/auth/qq_login_protocol.dart';
import 'package:motif/online/qq/auth/qq_session_manager.dart';
import 'package:motif/online/qq/qq_account_api.dart';
import 'package:motif/online/qq/qq_home_parser.dart';
import 'package:motif/online/qq/qq_home_models.dart';
import 'package:motif/online/qq/qq_music_client.dart';
import 'package:motif/online/qq/qq_response_parser.dart';

import 'online_fakes.dart';
import 'playback_fakes.dart';
import 'qq_auth_fakes.dart';

Map<String, Future<void> Function()> qqAuthChecks() => {
  'credentials normalize music identity and never expose key in diagnostics':
      () async {
        final credential = QqCredential.fromLoginData({
          'musicid': 'o00042',
          'musickey': 'fixture-secret',
          'nick': 'Name',
        });
        _check(credential.accountId == '42', 'Wrong normalized account');
        _check(
          !credential.toString().contains('fixture-secret'),
          'Credential diagnostic exposed a key',
        );
        final request = QqAccountRequest(
          uri: Uri.https('u.y.qq.com', '/'),
          cookie: credential.cookie,
        );
        _check(
          !request.toString().contains('fixture-secret'),
          'Request diagnostic exposed a key',
        );
      },
  'credential cookie control characters are rejected': () async {
    await _throws<QqAuthException>(
      () async => qqCookieValues('musickey=bad\r\nheader=x'),
    );
  },
  'expired duplicate cookies cannot erase a valid QQ OAuth ticket': () async {
    for (final deletion in [
      'p_skey=; Max-Age=0; Domain=.qq.com',
      'p_skey=deleted; expires=Thu, 01 Jan 1970 00:00:00 GMT',
    ]) {
      for (final cookies in [
        ['p_skey=fixture-skey; Domain=.graph.qq.com', deletion],
        [deletion, 'p_skey=fixture-skey; Domain=.graph.qq.com'],
      ]) {
        final response = accountResponse('', cookies: cookies);
        _check(
          qqCookieValues(response.cookie)['p_skey'] == 'fixture-skey',
          'Duplicate deletion erased a live OAuth ticket',
        );
      }
    }
  },
  'QQ OAuth accepts omitted or empty state and rejects a conflicting state':
      () async {
        const callback =
            'https://y.qq.com/portal/wx_redirect.html?code=fixture-code';
        for (final value in [callback, '$callback&state=']) {
          _check(
            qqAuthorizationCode(value, 'attempt-state') == 'fixture-code',
            'A reference-compatible callback was rejected',
          );
        }
        final error = await _throws<QqAuthException>(
          () async => qqAuthorizationCode(
            '$callback&state=other-attempt',
            'attempt-state',
          ),
        );
        _check(
          error.kind == QqAuthErrorKind.rejected,
          'A conflicting OAuth state was accepted',
        );
      },
  'secure envelope keeps one stable device across reopen': () async {
    final vault = MemoryQqVault();
    final first = QqSessionManager(vault: vault);
    await first.initialize();
    final id = first.deviceId;
    await first.close();
    final second = QqSessionManager(vault: vault);
    await second.initialize();
    _check(
      second.deviceId == id && second.account == null,
      'Device changed or empty session became logged in',
    );
    await second.close();
  },
  'cancelled login cannot persist or publish credentials': () async {
    final vault = MemoryQqVault();
    final session = QqSessionManager(vault: vault);
    await session.initialize();
    final attempt = await session.beginLogin();
    await session.cancelLogin(attempt);
    _check(
      !await session.completeLogin(attempt, testCredential()),
      'Cancelled login committed',
    );
    _check(
      jsonDecode(vault.value!)['credential'] == null,
      'Cancelled credentials persisted',
    );
    await session.close();
  },
  'logout wins over a pending secure login write': () async {
    final vault = MemoryQqVault();
    final session = QqSessionManager(vault: vault);
    await session.initialize();
    final attempt = await session.beginLogin();
    final pending = Completer<void>();
    vault.nextWriteWait = pending.future;
    final logging = session.completeLogin(attempt, testCredential());
    await Future<void>.delayed(Duration.zero);
    final logout = session.logout();
    pending.complete();
    _check(!await logging, 'Stale login published');
    await logout;
    _check(
      session.account == null && jsonDecode(vault.value!)['credential'] == null,
      'Logout was overwritten',
    );
    await session.close();
  },
  'old account rejection cannot sign out a new account': () async {
    final vault = MemoryQqVault();
    final session = await signedSession(vault);
    final old = session.snapshot;
    final attempt = await session.beginLogin();
    await session.completeLogin(attempt, testCredential(id: '84'));
    await session.reject(old);
    _check(session.account?.id == '84', 'Old rejection signed out new account');
    await session.close();
  },
  'unavailable vault prevents login and reports a recoverable storage error':
      () async {
        final vault = MemoryQqVault()..error = StateError('unavailable');
        final session = QqSessionManager(vault: vault);
        await session.initialize();
        _check(!session.isReady, 'Unavailable vault was marked ready');
        await _throws<QqAuthException>(() => session.beginLogin());
        vault.error = null;
        await session.initialize();
        _check(session.isReady, 'Storage initialization could not retry');
        await session.close();
      },
  'invalidation drops cached and late results without corrupting fresh work':
      () async {
        final clock = TestClock();
        final coordinator = clock.coordinator();
        final pending = Completer<Object>();
        final old = _throws<OnlineException>(
          () => coordinator.run(
            'same',
            ttl: const Duration(minutes: 1),
            request: () => pending.future,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        coordinator.invalidate();
        final fresh = coordinator.run(
          'same',
          ttl: const Duration(minutes: 1),
          request: () async => 'fresh',
        );
        pending.complete('old');
        await old;
        _check(await fresh == 'fresh', 'Stale result replaced fresh work');
        _check(
          await coordinator.run(
                'same',
                ttl: const Duration(minutes: 1),
                request: () async => 'unexpected',
              ) ==
              'fresh',
          'Stale result entered cache',
        );
        coordinator.close();
      },
  'invalidation preserves a stale server rate limit for queued new work':
      () async {
        final coordinator = TestClock().coordinator();
        final pending = Completer<Object>();
        final old = _throws<OnlineException>(
          () => coordinator.run(
            'old',
            ttl: Duration.zero,
            request: () => pending.future,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        coordinator.invalidate();
        var calls = 0;
        final fresh = _throws<OnlineException>(
          () => coordinator.run(
            'new',
            ttl: Duration.zero,
            request: () async {
              calls++;
              return 'bad';
            },
          ),
        );
        pending.completeError(
          const OnlineException(OnlineErrorKind.rateLimited),
        );
        await old;
        final error = await fresh;
        _check(
          error.kind == OnlineErrorKind.rateLimited && calls == 0,
          'Account change bypassed cooldown',
        );
        coordinator.close();
      },
  'QQ QR creation uses the tested app IDs and isolates qrsig': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (_) async => QqAccountResponse(
        status: 200,
        bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
        setCookies: ['qrsig=qr-fixture; Path=/'],
      );
    final client = QqAuthClient(transport: transport);
    final challenge = await client.createQr(
      QqQrMethod.qq,
      isActive: () => true,
    );
    final params = transport.requests.single.uri.queryParameters;
    _check(
      params['appid'] == '716027609' && params['pt_3rd_aid'] == '100497308',
      'Wrong QR app identity',
    );
    _check(challenge.cookie == 'qrsig=qr-fixture', 'Wrong QR attempt seed');
    _check(
      transport.requests.single.userAgent.startsWith('Mozilla/5.0'),
      'QR authorization did not use a browser user agent',
    );
    client.close();
  },
  'QQ QR waiting and expired states do not authorize': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (_) async =>
          accountResponse("ptuiCB('65','0','','0','expired','');");
    final client = QqAuthClient(transport: transport);
    final challenge = QqQrChallenge(
      key: 'sig',
      image: Uint8List(8),
      method: QqQrMethod.qq,
      cookie: 'qrsig=sig',
    );
    final result = await client.checkQr(
      challenge,
      'device123456789012',
      isActive: () => true,
    );
    _check(
      result.status == QqQrStatus.expired && transport.requests.length == 1,
      'Expired QR dispatched OAuth',
    );
    client.close();
  },
  'QQ QR success follows validated OAuth redirects and exchange envelope': () async {
    final transport = FakeQqAccountTransport();
    transport.reply = (request) async => switch (request.uri.path) {
      '/ptqrlogin' => accountResponse(
        "ptuiCB('0','0','https://ssl.ptlogin2.qq.com/check_sig?s=fixture','0','','');",
      ),
      '/check_sig' => accountResponse(
        '',
        status: 302,
        cookies: ['p_skey=fixture-skey; Secure'],
        location: 'https://graph.qq.com/oauth2.0/login_jump',
      ),
      '/oauth2.0/login_jump' => accountResponse(''),
      '/oauth2.0/authorize' => accountResponse(
        '',
        status: 302,
        location:
            'https://y.qq.com/portal/wx_redirect.html?code=fixture-code&state=${request.form!['state']}',
      ),
      _ => accountResponse({
        'code': 0,
        'qrLogin': {'code': 0, 'data': loginData()},
      }),
    };
    final client = QqAuthClient(transport: transport);
    final challenge = QqQrChallenge(
      key: 'sig',
      image: Uint8List(8),
      method: QqQrMethod.qq,
      cookie: 'qrsig=sig',
    );
    final result = await client.checkQr(
      challenge,
      'device123456789012',
      isActive: () => true,
    );
    _check(
      result.credential?.accountId == '42' && transport.requests.length == 5,
      'OAuth chain did not complete',
    );
    final module = transport.requests.last.jsonBody!['qrLogin'] as Map;
    _check(
      module['module'] == 'QQConnectLogin.LoginServer' &&
          module['method'] == 'QQLogin',
      'Wrong QR exchange',
    );
    client.close();
  },
  'QR redirect to an unrelated host never receives login cookies': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (_) async => accountResponse(
        "ptuiCB('0','0','https://evil.example/check_sig','0','','');",
      );
    final client = QqAuthClient(transport: transport);
    final challenge = QqQrChallenge(
      key: 'sig',
      image: Uint8List(8),
      method: QqQrMethod.qq,
    );
    await _throws<QqAuthException>(
      () =>
          client.checkQr(challenge, 'device123456789012', isActive: () => true),
    );
    _check(
      transport.requests.length == 1,
      'Cookies were forwarded to invalid redirect',
    );
    client.close();
  },
  'phone authentication uses the tested Android comm and message parameters':
      () async {
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {});
        final client = QqAuthClient(transport: transport);
        await client.sendCode(
          '13800000000',
          '86',
          'device123456789012',
          isActive: () => true,
        );
        final request = transport.requests.single.jsonBody!;
        final comm = request['comm'] as Map;
        final module = request['phoneLogin'] as Map;
        _check(
          comm['ct'] == 11 &&
              comm['cv'] == 14090008 &&
              comm['OpenUDID'] == 'device123456789012',
          'Wrong phone envelope',
        );
        _check(
          module['method'] == 'SendPhoneAuthCode' &&
              (module['param'] as Map)['phoneNo'] == '13800000000',
          'Wrong phone request',
        );
        client.close();
      },
  'invalid SMS codes are rejected before any request': () async {
    final transport = FakeQqAccountTransport();
    final client = QqAuthClient(transport: transport);
    await _throws<QqAuthException>(
      () => client.loginSms(
        '13800000000',
        'letters',
        'device123456789012',
        isActive: () => true,
      ),
    );
    _check(transport.requests.isEmpty, 'Invalid code contacted login service');
    client.close();
  },
  'human verification returns only an approved official page challenge':
      () async {
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'securityURL': 'https://ssl.captcha.qq.com/verify?fixture=1',
          }, code: 20276);
        final client = QqAuthClient(transport: transport);
        final error = await _throws<QqVerificationRequired>(
          () => client.sendCode(
            '13800000000',
            '86',
            'device123456789012',
            isActive: () => true,
          ),
        );
        _check(
          error.challenge.uri.host == 'ssl.captcha.qq.com',
          'Wrong verification origin',
        );
        client.close();
      },
  'credential renewal refuses a different returned account': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (request) async =>
          accountModuleResponse(request, loginData(id: '84'));
    final client = QqAuthClient(transport: transport);
    await _throws<QqAuthException>(
      () => client.refresh(
        testCredential(),
        'device123456789012',
        isActive: () => true,
      ),
    );
    client.close();
  },
  'daily recommendation requests directory 202 and caps output at thirty':
      () async {
        final vault = MemoryQqVault();
        final session = await signedSession(vault);
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'songlist': List.generate(40, (i) => songJson(mid: 'daily$i')),
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        final tracks = await api.daily();
        final params =
            ((transport.requests.single.jsonBody!['req_0'] as Map)['param']
                as Map);
        _check(
          tracks.length == 30 &&
              params['dirid'] == 202 &&
              params['enc_host_uin'] == '42',
          'Wrong daily identity or size',
        );
        api.close();
        await session.close();
      },
  'radio requests account radio 99 and never reuses a cached batch': () async {
    final session = await signedSession(MemoryQqVault());
    final transport = FakeQqAccountTransport()
      ..reply = (request) async => accountModuleResponse(request, {
        'tracks': [songJson()],
      });
    final api = QqAccountApi(
      sessions: session,
      transport: transport,
      coordinator: TestClock().coordinator(),
    );
    await api.radio();
    await api.radio();
    final request = transport.requests.first.jsonBody!;
    final params = ((request['songlist'] as Map)['param'] as Map);
    final comm = request['comm'] as Map;
    _check(
      transport.requests.length == 2 &&
          params['id'] == 99 &&
          params['num'] == 20,
      'Wrong radio batch',
    );
    _check(
      comm['uin'] == '42' &&
          comm['ct'] == 19 &&
          comm['authst'] == 'fixture-key',
      'Wrong radio auth envelope',
    );
    _check(
      transport.requests.first.userAgent == qqWebUserAgent &&
          transport.requests.first.origin == 'https://y.qq.com',
      'Radio headers did not match the web recommendation profile',
    );
    api.close();
    await session.close();
  },
  'authenticated vkey has one consistent music account in comm and params':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'midurlinfo': [
              {'result': 0, 'songmid': 'songMid1', 'purl': 'M500mediaMid1.mp3'},
            ],
            'sip': ['https://audio.example/'],
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        final stream = await api.resolve(
          playbackTrack(1),
          OnlineQuality.standard,
        );
        final request = transport.requests.single;
        final comm = request.jsonBody!['comm'] as Map;
        final params = ((request.jsonBody!['req_1'] as Map)['param'] as Map);
        _check(
          comm['qq'] == '42' &&
              params['uin'] == '42' &&
              request.cookie.contains('musickey=fixture-key'),
          'Inconsistent account ticket context',
        );
        _check(stream.sourceId == 'qq', 'Wrong playback identity');
        api.close();
        await session.close();
      },
  'playlist pages use the verified web schema and preserve auth fields':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'songlist': [songJson()],
            'total_song_num': 101,
            'hasmore': 1,
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        final page = await api.playlistPage(
          const QqPlaylist(id: '123', title: 'Remote'),
          offset: 50,
        );
        final comm = transport.requests.single.jsonBody!['comm'] as Map;
        _check(
          comm['ct'] == 19 &&
              comm['cv'] == 0 &&
              !comm.containsKey('v') &&
              comm['authst'] == 'fixture-key',
          'Playlist schema drifted',
        );
        _check(
          transport.requests.single.userAgent == qqPlaylistUserAgent,
          'Playlist request used a different client version',
        );
        _check(page.hasMore && page.offset == 50, 'Playlist cursor lost');
        api.close();
        await session.close();
      },
  'recent playlist mapping never fabricates favorites or played-songs IDs':
      () async {
        final values = parseQqRecentPlaylists({
          'data': {
            'geDanList': [
              {'id': 123, 'name': '红心歌单', 'index': 1, 'num': 50},
              {'id': 456, 'name': 'Other', 'index': 0},
            ],
          },
        });
        _check(
          values.length == 2 &&
              values[1].id == '123' &&
              values.first.id == '456',
          'Recent playlist identity/order changed',
        );
      },
  'compact feed song ID is hydrated and never used as a playback MID':
      () async {
        final reference = parseQqRecommendedSong({
          'ID': 501,
          'Name': 'Short',
          'SingerName': 'Artist',
        })!;
        _check(
          reference.track == null && reference.songId == 501,
          'Catalog ID was fabricated as MID',
        );
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'track_info': songJson(mid: 'realMID')..['id'] = 501,
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        final track = await api.songDetail(reference);
        _check(
          track.mid == 'realMID' && track.songId == 501,
          'Song detail did not hydrate identity',
        );
        final comm = transport.requests.single.jsonBody!['comm'] as Map;
        _check(
          comm['ct'] == 24 &&
              comm['cv'] == 4747474 &&
              comm['uin'] == '42' &&
              transport.requests.single.userAgent == qqWebUserAgent,
          'Song detail did not use the reference web profile',
        );
        api.close();
        await session.close();
      },
  'feed parses music cards while ignoring listening programs': () async {
    final feed = parseQqHomeFeed({
      'v_shelf': [
        {
          'id': '315',
          'title': 'Songs',
          'v_niche': [
            {
              'style': 10001,
              'v_card': [
                {
                  'id': '42',
                  'type': 200,
                  'style': 208,
                  'title': 'Song',
                  'subtitle': 'Artist',
                },
                {'id': '123', 'type': 500, 'style': 302, 'title': 'Playlist'},
                {
                  'id': '999',
                  'type': 1700,
                  'title': 'Program',
                  'subtitle': 'Narrator',
                },
              ],
            },
          ],
        },
      ],
      'load_mark': 0,
    }, page: 1);
    _check(
      feed.shelves.single.pages.single.single.songId == 42 &&
          feed.playlists.single.id == '123',
      'Feed mixed business cards',
    );
    _check(feed.uniqueKeys.contains('200_0_42'), 'Feed cursor key missing');
  },
  'account change prevents a late recommendation response from publishing':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport();
        final pending = Completer<QqAccountResponse>();
        transport.reply = (_) => pending.future;
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        final result = _throws<OnlineException>(() => api.daily());
        await Future<void>.delayed(Duration.zero);
        await session.logout();
        pending.complete(
          accountModuleResponse(transport.requests.single, {
            'songlist': [songJson()],
          }),
        );
        final error = await result;
        _check(
          error.kind == OnlineErrorKind.sessionChanged,
          'Old account response was published',
        );
        api.close();
        await session.close();
      },
  'feed pagination accumulates server shelf count and distinct cache identities':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'v_shelf': [
              {'id': 'one'},
              {'id': 'two'},
            ],
            'load_mark': 1,
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        final first = await api.homeFeed();
        final second = await api.homeFeed(previous: first);
        await api.homeFeed(previous: second);
        final params =
            ((transport.requests.last.jsonBody!['req_0'] as Map)['param']
                as Map);
        _check(
          params['s_num'] == 4 && (params['v_cache'] as List).length == 2,
          'Feed cursor did not accumulate shelves',
        );
        _check(
          first.hasMore,
          'Unrelated load_mark incorrectly ended pagination',
        );
        api.close();
        await session.close();
      },
  'anonymous vkey uses the mobile envelope with the chosen quality': () async {
    final transport = FakeQqTransport()
      ..reply = (_) async => moduleResponse({
        'midurlinfo': [
          {'result': 0, 'songmid': 'songMid001', 'purl': 'M800media001.mp3'},
        ],
        'sip': ['https://audio.example/'],
      });
    final client = testClient(transport, TestClock());
    try {
      await client.resolve(parseQqTrack(songJson()), OnlineQuality.high);
      final request = transport.requests.single;
      final comm = request.jsonBody!['comm'] as Map;
      _check(
        comm['ct'] == 11 &&
            comm['cv'] == 14090008 &&
            comm['v'] == 14090008 &&
            comm['qq'] == '' &&
            comm['authst'] == '' &&
            request.userAgent == qqMusicUserAgent,
        'Anonymous playback mixed mobile parameters with a web envelope',
      );
    } finally {
      client.close();
    }
  },
  'signed search carries the current account through the private transport':
      () async {
        final session = await signedSession(MemoryQqVault());
        final private = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'body': {
              'song': [songJson()],
            },
            'meta': {'sum': 31},
          });
        final public = FakeQqTransport()..reply = (_) async => searchResponse();
        final api = QqAccountApi(
          sessions: session,
          transport: private,
          coordinator: TestClock().coordinator(),
        );
        final client = QqMusicClient(transport: public, accountApi: api);
        try {
          final result = await client.search(' Song ', page: 2);
          _check(
            private.requests.length == 1 && public.requests.isEmpty,
            'Signed search used the anonymous catalog transport',
          );
          final request = private.requests.single;
          final comm = request.jsonBody!['comm'] as Map;
          final module = request.jsonBody!['SONG'] as Map;
          final params = module['param'] as Map;
          _check(
            comm['ct'] == 19 &&
                comm['cv'] == 1859 &&
                comm['v'] == 1859 &&
                comm['qq'] == '42' &&
                comm['uin'] == '42' &&
                comm['authst'] == 'fixture-key' &&
                request.userAgent == qqSearchUserAgent &&
                request.cookie.contains('musickey=fixture-key') &&
                module['method'] == 'DoSearchForQQMusicDesktop' &&
                params['page_num'] == 2 &&
                params['sin'] == 30 &&
                result.tracks.single.mid == 'songMid001',
            'Signed search request or response lost its protocol context',
          );
        } finally {
          client.close();
          api.close();
          await session.close();
        }
      },
  'signed MID detail uses the web profile and retains the private cookie':
      () async {
        final session = await signedSession(MemoryQqVault());
        final private = FakeQqAccountTransport()
          ..reply = (request) async =>
              accountModuleResponse(request, {'track_info': songJson()});
        final public = FakeQqTransport()
          ..reply = (_) async => moduleResponse({'track_info': songJson()});
        final api = QqAccountApi(
          sessions: session,
          transport: private,
          coordinator: TestClock().coordinator(),
        );
        final client = QqMusicClient(transport: public, accountApi: api);
        try {
          final result = await client.detail('songMid001');
          _check(
            private.requests.length == 1 && public.requests.isEmpty,
            'Signed detail used the anonymous catalog transport',
          );
          final request = private.requests.single;
          final comm = request.jsonBody!['comm'] as Map;
          _check(
            comm['ct'] == 24 &&
                comm['cv'] == 4747474 &&
                comm['uin'] == '42' &&
                request.userAgent == qqWebUserAgent &&
                request.origin == 'https://y.qq.com' &&
                request.cookie.contains('musickey=fixture-key') &&
                result.mid == 'songMid001',
            'Signed detail profile or identity did not match',
          );
        } finally {
          client.close();
          api.close();
          await session.close();
        }
      },
  'daily recommendation preserves the alternate encrypted account field':
      () async {
        final session = await signedSession(MemoryQqVault());
        final attempt = await session.beginLogin();
        await session.completeLogin(
          attempt,
          QqCredential.fromLoginData({
            ...loginData(),
            'encrypt_uin': 'fixture-encrypted-account',
          }),
        );
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'songlist': [songJson()],
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        try {
          await api.daily();
          final params =
              (transport.requests.single.jsonBody!['req_0'] as Map)['param']
                  as Map;
          _check(
            params['enc_host_uin'] == 'fixture-encrypted-account',
            'Daily recommendation discarded the encrypted identity alias',
          );
        } finally {
          api.close();
          await session.close();
        }
      },
  'official playback risk responses open verification and resume once':
      () async {
        for (final code in [2001, 104009]) {
          for (final level in ['root', 'module', 'item']) {
            final session = await signedSession(MemoryQqVault());
            final transport = FakeQqAccountTransport();
            final field = code == 2001 ? 'feedbackURL' : 'validURL';
            final url = 'https://ssl.captcha.tencent.com/verify?fixture=1';
            transport.reply = (request) async {
              if (transport.requests.length > 1) {
                return accountModuleResponse(request, {
                  'midurlinfo': [
                    {'result': 0, 'purl': 'M500mediaMid1.mp3'},
                  ],
                  'sip': ['https://audio.example/'],
                });
              }
              if (level == 'root') {
                return accountResponse({
                  'code': code,
                  'data': {field: url},
                });
              }
              if (level == 'module') {
                return accountModuleResponse(request, {field: url}, code: code);
              }
              return accountModuleResponse(request, {
                field: url,
                'midurlinfo': [
                  {'result': code},
                ],
              });
            };
            var verifications = 0;
            final api =
                QqAccountApi(
                    sessions: session,
                    transport: transport,
                    coordinator: TestClock().coordinator(),
                  )
                  ..verify = (challenge) async {
                    verifications++;
                    _check(
                      challenge.uri.host == 'ssl.captcha.tencent.com' &&
                          (code != 104009 ||
                              challenge.uri.queryParameters['_vkey_verify'] ==
                                  '1') &&
                          challenge.cookie.contains('musickey=fixture-key'),
                      'Verification URI or account proof context was lost',
                    );
                    return const QqVerificationResult(
                      cookie: 'proof=fixture-proof',
                    );
                  };
            try {
              final result = await api.resolve(
                playbackTrack(1),
                OnlineQuality.standard,
              );
              _check(
                verifications == 1 &&
                    transport.requests.length == 2 &&
                    transport.requests.last.cookie.contains(
                      'proof=fixture-proof',
                    ) &&
                    result.uri.scheme == 'https',
                'Official risk verification did not resume exactly once',
              );
            } finally {
              api.close();
              await session.close();
            }
          }
        }
      },
  'untrusted risk URLs never receive a verification session': () async {
    for (final url in [
      'http://ssl.captcha.qq.com/verify',
      'https://qq.com.evil.example/verify',
      'https://user:secret@ssl.captcha.qq.com/verify',
    ]) {
      final session = await signedSession(MemoryQqVault());
      final transport = FakeQqAccountTransport()
        ..reply = (request) async =>
            accountModuleResponse(request, {'feedbackURL': url}, code: 2001);
      var verifications = 0;
      final api =
          QqAccountApi(
              sessions: session,
              transport: transport,
              coordinator: TestClock().coordinator(),
            )
            ..verify = (_) async {
              verifications++;
              return null;
            };
      try {
        final error = await _throws<OnlineException>(
          () => api.resolve(playbackTrack(1), OnlineQuality.standard),
        );
        _check(
          error.kind == OnlineErrorKind.rejected &&
              verifications == 0 &&
              transport.requests.length == 1 &&
              session.account?.id == '42',
          'Untrusted risk URL opened a page or invalidated a live account',
        );
      } finally {
        api.close();
        await session.close();
      }
    }
  },
  'vkey item expiry invalidates the owning account instead of an unavailable song':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'midurlinfo': [
              {'result': 104400, 'purl': 'M500mediaMid1.mp3'},
            ],
            'sip': ['https://audio.example/'],
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        try {
          final error = await _throws<OnlineException>(
            () => api.resolve(playbackTrack(1), OnlineQuality.standard),
          );
          _check(
            error.kind == OnlineErrorKind.sessionExpired &&
                session.status == QqSessionStatus.expired &&
                transport.requests.length == 1,
            'A rejected vkey credential was reported as a missing song',
          );
        } finally {
          api.close();
          await session.close();
        }
      },
  'business rate limits stop later catalog requests without signing out': () async {
    for (final code in [100001, 104604]) {
      final session = await signedSession(MemoryQqVault());
      final transport = FakeQqAccountTransport()
        ..reply = (_) async => accountResponse({'code': code});
      final api = QqAccountApi(
        sessions: session,
        transport: transport,
        coordinator: TestClock().coordinator(),
      );
      try {
        final first = await _throws<OnlineException>(api.daily);
        final second = await _throws<OnlineException>(api.recentPlaylists);
        _check(
          first.kind == OnlineErrorKind.rateLimited &&
              second.kind == OnlineErrorKind.rateLimited &&
              transport.requests.length == 1 &&
              session.account?.id == '42',
          'A business rate limit bypassed cooldown or signed out the account',
        );
      } finally {
        api.close();
        await session.close();
      }
    }
  },
  'a completed proof does not repeatedly open a cached security challenge':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport();
        transport.reply = (request) async => transport.requests.length == 1
            ? accountModuleResponse(request, {
                'feedbackURL': 'https://ssl.captcha.qq.com/verify',
              }, code: 2001)
            : accountModuleResponse(request, {'List': <Object?>[]});
        var verifications = 0;
        final api =
            QqAccountApi(
                sessions: session,
                transport: transport,
                coordinator: TestClock().coordinator(),
              )
              ..verify = (_) async {
                verifications++;
                return const QqVerificationResult(
                  cookie: 'proof=fixture-proof',
                );
              };
        try {
          await api.personalizedPlaylists();
          await api.personalizedPlaylists();
          await api.personalizedPlaylists();
          _check(
            verifications == 1 && transport.requests.length == 3,
            'An obsolete cached challenge reopened verification',
          );
        } finally {
          api.close();
          await session.close();
        }
      },
  'QQ playback accepts server scheme-relative and wifi URLs over HTTPS': () async {
    final cases = <Map<String, Object?>>[
      {
        'midurlinfo': [
          {
            'result': 0,
            'purl': '//audio.example/M500mediaMid1.mp3?vkey=fixture',
          },
        ],
      },
      {
        'midurlinfo': [
          {'result': 0, 'purl': 'M500mediaMid1.mp3'},
        ],
        'sip': ['//audio.example/'],
      },
      {
        'midurlinfo': [
          {
            'result': 0,
            'purl': '',
            'wifiurl': 'http://audio.example/M500mediaMid1.mp3',
          },
        ],
      },
    ];
    for (final data in cases) {
      final public = FakeQqTransport()
        ..reply = (_) async => moduleResponse(data);
      final client = testClient(public, TestClock());
      final session = await signedSession(MemoryQqVault());
      final private = FakeQqAccountTransport()
        ..reply = (request) async => accountModuleResponse(request, data);
      final api = QqAccountApi(
        sessions: session,
        transport: private,
        coordinator: TestClock().coordinator(),
      );
      try {
        final streams = [
          await client.resolve(playbackTrack(1), OnlineQuality.standard),
          await api.resolve(playbackTrack(1), OnlineQuality.standard),
        ];
        _check(
          streams.every(
                (stream) =>
                    stream.uri.scheme == 'https' &&
                    stream.uri.host == 'audio.example' &&
                    stream.uri.pathSegments.last == 'M500mediaMid1.mp3',
              ) &&
              public.requests.length == 1 &&
              private.requests.length == 1,
          'A server URL variant was lost or triggered extra ticket requests',
        );
      } finally {
        client.close();
        api.close();
        await session.close();
      }
    }
  },
  'QQ QR completes with duplicate ticket cookies and a legacy graph jump':
      () async {
        for (final jump in [
          '/oauth2.0/login_jump?fixture=1',
          'http://graph.qq.com/oauth2.0/login_jump?fixture=1',
        ]) {
          final transport = FakeQqAccountTransport()
            ..reply = (request) async =>
                _qqQrReply(request, jump: jump, emptyState: true);
          final client = QqAuthClient(transport: transport);
          try {
            final result = await client.checkQr(
              _qqQrChallenge(),
              'device123456789012',
              isActive: () => true,
            );
            final authorize = transport.requests[3];
            _check(
              result.status == QqQrStatus.success &&
                  result.credential?.accountId == '42' &&
                  transport.requests.length == 5 &&
                  transport.requests.every(
                    (request) => request.uri.scheme == 'https',
                  ) &&
                  authorize.form!['g_tk'] ==
                      '${qqQrToken('fixture-skey', seed: 5381)}' &&
                  authorize.cookie.contains('p_skey=fixture-skey') &&
                  !transport.requests.last.cookie.contains('p_skey'),
              'The compatible OAuth flow lost its ticket or exposed it to music exchange',
            );
          } finally {
            client.close();
          }
        }
      },
  'QQ QR failures retain their safe phase and HTTP or API error code':
      () async {
        for (final status in [403, 302]) {
          final transport = FakeQqAccountTransport()
            ..reply = (request) async => _qqQrReply(
              request,
              authorizationStatus: status,
              exchangeCode: 2002,
            );
          final client = QqAuthClient(transport: transport);
          try {
            final error = await _throws<QqAuthException>(
              () => client.checkQr(
                _qqQrChallenge(),
                'device123456789012',
                isActive: () => true,
              ),
            );
            _check(
              status == 403
                  ? error.stage == QqAuthStage.authorization &&
                        error.httpStatus == 403
                  : error.stage == QqAuthStage.exchange &&
                        error.apiCode == 2002,
              'The failed protocol phase was erased',
            );
            _check(
              !error.toString().contains('fixture-skey') &&
                  !error.toString().contains('fixture-code') &&
                  !error.toString().contains('fixture-qrsig') &&
                  !error.toString().contains('https://'),
              'Failure diagnostics exposed an OAuth secret or URL',
            );
          } finally {
            client.close();
          }
        }
      },
  'an empty OAuth ticket expires before the authorization request': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (request) async => request.uri.path == '/check_sig'
          ? accountResponse('', status: 302, cookies: ['p_skey=; Max-Age=0'])
          : _qqQrReply(request);
    final client = QqAuthClient(transport: transport);
    try {
      final error = await _throws<QqAuthException>(
        () => client.checkQr(
          _qqQrChallenge(),
          'device123456789012',
          isActive: () => true,
        ),
      );
      _check(
        error.kind == QqAuthErrorKind.expired &&
            error.stage == QqAuthStage.signature &&
            transport.requests.length == 2,
        'An empty ticket was sent to OAuth and misreported as login rejection',
      );
    } finally {
      client.close();
    }
  },
  'QR exchange verification retains the response proof cookie': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (request) async => request.uri.host == 'u.y.qq.com'
          ? accountResponse(
              {
                'code': 2001,
                'data': {'feedbackURL': 'https://ssl.captcha.qq.com/verify'},
              },
              cookies: ['proof_session=fixture-server-proof; Secure'],
            )
          : _qqQrReply(request);
    final client = QqAuthClient(transport: transport);
    try {
      final error = await _throws<QqVerificationRequired>(
        () => client.checkQr(
          _qqQrChallenge(),
          'device123456789012',
          isActive: () => true,
        ),
      );
      _check(
        error.challenge.cookie.contains('proof_session=fixture-server-proof') &&
            !error.challenge.cookie.contains('p_skey'),
        'Exchange verification lost its response cookie or reused a graph ticket',
      );
    } finally {
      client.close();
    }
  },
  'WeChat creation uses the official UUID page and isolated browser cookies': () async {
    final transport = FakeQqAccountTransport()
      ..reply = (request) async => request.uri.path == '/connect/qrconnect'
          ? accountResponse(
              '<img src="/connect/qrcode/wx_uuid">',
              cookies: ['wx_session=fixture'],
            )
          : QqAccountResponse(
              status: 200,
              bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
            );
    final client = QqAuthClient(transport: transport);
    try {
      final qr = await client.createQr(QqQrMethod.wechat, isActive: () => true);
      _check(
        qr.key == 'wx_uuid' &&
            qr.method == QqQrMethod.wechat &&
            transport.requests.length == 2 &&
            transport.requests.first.uri.queryParameters['scope'] ==
                'snsapi_login' &&
            transport.requests.last.cookie == 'wx_session=fixture' &&
            transport.requests.every(
              (request) => request.userAgent == qqBrowserUserAgent,
            ),
        'WeChat QR creation lost its UUID, browser profile or attempt cookie',
      );
    } finally {
      client.close();
    }
  },
  'WeChat approval exchanges a distinct login type and Android envelope':
      () async {
        final transport = FakeQqAccountTransport()
          ..reply = (request) async =>
              request.uri.host == 'lp.open.weixin.qq.com'
              ? accountResponse(
                  "window.wx_errcode=405;window.wx_code='fixture-code';",
                )
              : accountResponse({
                  'code': 0,
                  'qrLogin': {'code': 0, 'data': loginData()},
                });
        final client = QqAuthClient(transport: transport);
        try {
          final qr = QqQrChallenge(
            key: 'wx_uuid',
            image: Uint8List(8),
            method: QqQrMethod.wechat,
          );
          final result = await client.checkQr(
            qr,
            'device123456789012',
            isActive: () => true,
          );
          final request = transport.requests.last.jsonBody!;
          final comm = request['comm'] as Map;
          final module = request['qrLogin'] as Map;
          _check(
            result.credential?.loginType == 1 &&
                comm['ct'] == 11 &&
                comm['cv'] == 14090008 &&
                comm['tmeLoginType'] == 1 &&
                !comm.containsKey('tmeLoginMethod') &&
                module['module'] == 'music.login.LoginServer' &&
                module['method'] == 'Login',
            'WeChat credentials were exchanged using the QQ identity type',
          );
        } finally {
          client.close();
        }
      },
  'WeChat long poll timeouts keep an active QR but do not mask network failures':
      () async {
        final qr = QqQrChallenge(
          key: 'wx_uuid',
          image: Uint8List(8),
          method: QqQrMethod.wechat,
        );
        for (final kind in [
          QqAuthErrorKind.timeout,
          QqAuthErrorKind.transport,
        ]) {
          final transport = FakeQqAccountTransport()
            ..reply = (_) async => throw QqAuthException(kind);
          final client = QqAuthClient(transport: transport);
          try {
            if (kind == QqAuthErrorKind.timeout) {
              final result = await client.checkQr(
                qr,
                'device123456789012',
                isActive: () => true,
              );
              _check(
                result.status == QqQrStatus.waitingScan &&
                    identical(result.challenge, qr),
                'Long poll timeout discarded the QR',
              );
            } else {
              final error = await _throws<QqAuthException>(
                () => client.checkQr(
                  qr,
                  'device123456789012',
                  isActive: () => true,
                ),
              );
              _check(
                error.kind == QqAuthErrorKind.transport,
                'A network failure was hidden as a poll timeout',
              );
            }
            _check(
              transport.requests.length == 1,
              'Timeout recreated a QR or dispatched an exchange',
            );
          } finally {
            client.close();
          }
        }
      },
  'renewal preserves account type and the reference refresh parameters':
      () async {
        final previous = QqCredential.fromLoginData({
          ...loginData(),
          'openid': 'fixture-openid',
          'refresh_key': 'fixture-refresh',
          'expired_at': 1234567890,
        });
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'musickey': 'fixture-new-key',
            'expired_at': 2000000000,
          });
        final client = QqAuthClient(transport: transport);
        try {
          final result = await client.refresh(
            previous,
            'device123456789012',
            isActive: () => true,
          );
          final body = transport.requests.single.jsonBody!;
          final comm = body['comm'] as Map;
          final params = (body['phoneLogin'] as Map)['param'] as Map;
          _check(
            result.accountId == '42' &&
                result.musicKey == 'fixture-new-key' &&
                result.loginType == 2 &&
                comm['qq'] == '42' &&
                comm['tmeLoginType'] == 2 &&
                comm['authst'] == 'fixture-key' &&
                params['openid'] == 'fixture-openid' &&
                params['refresh_key'] == 'fixture-refresh' &&
                params['expired_in'] == 1234567890 &&
                params['loginMode'] == 2,
            'Renewal changed identity or dropped the reference refresh context',
          );
        } finally {
          client.close();
        }
      },
  'personalized playlists request the reference offset and cap eight items':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'List': List.generate(
              12,
              (i) => {
                'Playlist': {
                  'basic': {'tid': i + 1, 'title': 'Playlist $i'},
                },
              },
            ),
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        try {
          final result = await api.personalizedPlaylists(page: 2);
          final request = transport.requests.single.jsonBody!;
          final comm = request['comm'] as Map;
          final module = request['req_0'] as Map;
          final params = module['param'] as Map;
          _check(
            result.length == 8 &&
                params['From'] == 16 &&
                params['Size'] == 8 &&
                module['method'] == 'GetRecommendFeed' &&
                comm['ct'] == 11 &&
                comm['qq'] == '42',
            'Personalized playlist request or response limit drifted',
          );
        } finally {
          api.close();
          await session.close();
        }
      },
  'recent playlists request type four with the current mobile account':
      () async {
        final session = await signedSession(MemoryQqVault());
        final transport = FakeQqAccountTransport()
          ..reply = (request) async => accountModuleResponse(request, {
            'data': {
              'geDanList': [
                {'id': 123, 'name': '红心歌单'},
              ],
            },
          });
        final api = QqAccountApi(
          sessions: session,
          transport: transport,
          coordinator: TestClock().coordinator(),
        );
        try {
          final result = await api.recentPlaylists();
          final request = transport.requests.single.jsonBody!;
          final comm = request['comm'] as Map;
          final module = request['req_1'] as Map;
          final params = module['param'] as Map;
          _check(
            result.single.id == '123' &&
                module['method'] == 'GetPlayRecentlyInfo' &&
                params['type'] == 4 &&
                params['requestCnt'] == 500 &&
                comm['ct'] == 11 &&
                comm['qq'] == '42' &&
                transport.requests.single.userAgent == qqMusicUserAgent,
            'Recent playlists drifted to played songs or another account',
          );
        } finally {
          api.close();
          await session.close();
        }
      },
  'signed search cannot publish a response after switching accounts': () async {
    final session = await signedSession(MemoryQqVault());
    final pending = Completer<QqAccountResponse>();
    final transport = FakeQqAccountTransport()..reply = (_) => pending.future;
    final api = QqAccountApi(
      sessions: session,
      transport: transport,
      coordinator: TestClock().coordinator(),
    );
    try {
      final searching = _throws<OnlineException>(() => api.search('Song'));
      await Future<void>.delayed(Duration.zero);
      final attempt = await session.beginLogin();
      await session.completeLogin(attempt, testCredential(id: '84'));
      pending.complete(
        accountModuleResponse(transport.requests.single, {
          'body': {
            'song': [songJson()],
          },
        }),
      );
      final error = await searching;
      _check(
        error.kind == OnlineErrorKind.sessionChanged &&
            session.account?.id == '84',
        'Old search data reached the new account',
      );
    } finally {
      api.close();
      await session.close();
    }
  },
};

QqQrChallenge _qqQrChallenge() => QqQrChallenge(
  key: 'fixture-qrsig',
  image: Uint8List(8),
  method: QqQrMethod.qq,
  cookie: 'qrsig=fixture-qrsig',
);

QqAccountResponse _qqQrReply(
  QqAccountRequest request, {
  String jump = 'https://graph.qq.com/oauth2.0/login_jump',
  bool emptyState = false,
  int authorizationStatus = 302,
  int exchangeCode = 0,
}) => switch (request.uri.path) {
  '/ptqrlogin' => accountResponse(
    "ptuiCB('0','0','https://ssl.ptlogin2.graph.qq.com/check_sig?ptsigx=fixture','0','','');",
  ),
  '/check_sig' => accountResponse(
    '',
    status: 302,
    cookies: [
      'p_skey=fixture-skey; Domain=.graph.qq.com',
      'p_skey=; Max-Age=0; Domain=.qq.com',
    ],
    location: jump,
  ),
  '/oauth2.0/login_jump' => accountResponse(''),
  '/oauth2.0/authorize' => accountResponse(
    '',
    status: authorizationStatus,
    location:
        'https://y.qq.com/portal/wx_redirect.html?code=fixture-code&state=${emptyState ? '' : request.form!['state']}',
  ),
  _ => accountResponse({
    'code': 0,
    'qrLogin': {'code': exchangeCode, 'data': loginData()},
  }),
};

void _check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<T> _throws<T>(Future<dynamic> Function() operation) async {
  try {
    await operation();
  } catch (error) {
    if (error is T) return error as T;
    throw StateError('Expected $T, received ${error.runtimeType}');
  }
  throw StateError('Expected $T');
}

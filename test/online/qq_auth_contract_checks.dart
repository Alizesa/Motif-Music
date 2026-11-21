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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/network/qq_http_transport.dart';
import 'package:motif/online/qq/qq_response_parser.dart';

import 'online_fakes.dart';
import 'request_coordinator_test.dart' show kind;

void main() {
  late FakeQqTransport http;
  late TestClock clock;
  setUp(() {
    http = FakeQqTransport();
    clock = TestClock();
  });

  test(
    'startup does no network and identical normalized searches coalesce',
    () async {
      http.reply = (_) async => searchResponse();
      final api = testClient(http, clock);
      addTearDown(api.close);
      expect(http.requests, isEmpty);
      final pages = await Future.wait([
        api.search('  周杰伦   稻香 '),
        api.search('周杰伦 稻香'),
      ]);
      expect(http.requests.length, 1);
      expect(pages.first.tracks.single.mid, 'songMid001');
      final uri = http.requests.single.uri;
      expect(uri.host, 'u.y.qq.com');
      expect(uri.scheme, 'https');
      final module = http.requests.single.jsonBody!['SONG'] as Map;
      expect(module['module'], 'music.search.SearchCgiService');
      expect(module['method'], 'DoSearchForQQMusicDesktop');
      expect((module['param'] as Map)['query'], '周杰伦 稻香');
      expect(http.requests.single.userAgent, 'QQMusic 20050009(android 14)');
    },
  );

  test('pagination is explicit and search results never trigger detail or URL probes', () async {
    http.reply = (_) async => searchResponse(total: 45);
    final api = testClient(http, clock);
    addTearDown(api.close);
    final page = await api.search('Song');
    expect(page.hasMore, isTrue);
    expect(http.requests.length, 1);
    await api.search('Song', page: 2);
    expect(http.requests.length, 2);
    final module = http.requests.last.jsonBody!['SONG'] as Map;
    expect((module['param'] as Map)['page_num'], 2);
    expect(http.requests.every((r) => r.jsonBody!.containsKey('SONG')), isTrue);
  });

  test('invalid search input is rejected before queueing anything', () {
    final api = testClient(http, clock);
    addTearDown(api.close);
    expect(() => api.search('  '), throwsArgumentError);
    expect(() => api.search('Song', pageSize: 31), throwsArgumentError);
    expect(() => api.search('Song', page: 0), throwsArgumentError);
    expect(() => api.detail('../secret'), throwsArgumentError);
    expect(http.requests, isEmpty);
  });

  test('legacy and current QQ fields preserve identity, duration and version words', () {
    for (final legacy in [true, false]) {
      final track = parseQqTrack({
        ...songJson(legacy: legacy),
        'subtitle': 'Live',
      });
      expect(track.title, 'Song (Live)');
      expect(track.songId, 42);
      expect(track.mediaMid, 'media001');
      expect(track.metadata.artist, 'Artist');
      expect(track.durationMs, 180000);
      expect(track.qualitySizes[OnlineQuality.high], greaterThan(0));
      expect(track.metadata.quality.hasKnownMetric, isFalse);
    }
  });

  test('missing values stay unknown and encoded titles are decoded without guessing', () {
    final json = songJson()
      ..remove('interval')
      ..remove('singer')
      ..remove('file');
    json['name'] = 'Song &amp; Remix &#x4e00;';
    final track = parseQqTrack(json);
    expect(track.title, 'Song & Remix 一');
    expect(track.durationMs, isNull);
    expect(track.artists, isEmpty);
    expect(track.mediaMid, isNull);
    expect(track.qualitySizes, isEmpty);
    expect(track.metadata.quality.hasKnownMetric, isFalse);
  });

  test(
    'invalid siblings are dropped and duplicate mids do not create duplicates',
    () async {
      http.reply = (_) async => searchResponse(
        tracks: [
          songJson(),
          {'mid': 'bad'},
          songJson(),
        ],
      );
      final api = testClient(http, clock);
      addTearDown(api.close);
      expect((await api.search('Song')).tracks.length, 1);
      expect(http.requests.length, 1);
    },
  );

  test(
    'malformed success is negative cached instead of cached as an empty result',
    () async {
      http.reply = (_) async => jsonResponse({'code': 0, 'data': {}});
      final api = testClient(http, clock);
      addTearDown(api.close);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          api.search('Song'),
          throwsA(kind(OnlineErrorKind.malformedResponse)),
        );
      }
      expect(http.requests.length, 1);
    },
  );

  test(
    'search and detail TTLs are independent with no background refresh',
    () async {
      http.reply = (r) async => r.jsonBody!.containsKey('SONG')
          ? searchResponse()
          : moduleResponse({'track_info': songJson()});
      final api = testClient(http, clock);
      addTearDown(api.close);
      await api.search('Song');
      await api.detail('songMid001');
      clock.advance(const Duration(minutes: 11));
      await api.detail('songMid001');
      await api.search('Song');
      expect(http.requests.length, 3);
      clock.advance(const Duration(hours: 24));
      await api.detail('songMid001');
      expect(http.requests.length, 4);
    },
  );

  test(
    'detail checks returned identity and makes only one module call',
    () async {
      http.reply = (_) async =>
          moduleResponse({'track_info': songJson(mid: 'wrongMid')});
      final api = testClient(http, clock);
      addTearDown(api.close);
      await expectLater(
        api.detail('songMid001'),
        throwsA(kind(OnlineErrorKind.malformedResponse)),
      );
      expect(http.requests.length, 1);
      final req = http.requests.single.jsonBody!['req_1'] as Map;
      expect(req['module'], 'music.pf_song_detail_svr');
      expect(req['method'], 'get_song_detail_yqq');
    },
  );

  test(
    'one chosen tier makes one ticket request and caches its URL briefly',
    () async {
      http.reply = (_) async => moduleResponse({
        'midurlinfo': [
          {
            'result': 0,
            'songmid': 'songMid001',
            'purl': 'M800media001.mp3?vkey=example',
          },
        ],
        'sip': ['http://media.example/', 'https://media.example/'],
      });
      final api = testClient(http, clock);
      addTearDown(api.close);
      final track = parseQqTrack(songJson());
      final first = await api.resolve(track, OnlineQuality.high);
      await api.resolve(track, OnlineQuality.high);
      expect(http.requests.length, 1);
      expect(first.uri.scheme, 'https');
      expect(first.requestedQuality, OnlineQuality.high);
      expect(first.reportedQuality, isNull);
      final params =
          (http.requests.single.jsonBody!['req_1'] as Map)['param'] as Map;
      expect(params['filename'], ['M800media001.mp3']);
      expect(params['songmid'], ['songMid001']);
      expect(params['uin'], '0');
      expect(params['guid'], '1234567890');
      expect(params['platform'], '23');
      expect(params['quality'], 'M800');
      expect(params['h5queryversion'], 1);
      expect(params['firstlogin'], 1);
      expect(params['newver'], 1);
      expect(params['nohash'], 0);
      clock.advance(const Duration(seconds: 31));
      await api.resolve(track, OnlineQuality.high);
      expect(http.requests.length, 2);
      final again =
          (http.requests.last.jsonBody!['req_1'] as Map)['param'] as Map;
      expect(again['guid'], params['guid']);
    },
  );

  for (final filename in [
    'M500media001.mp3',
    'C400media001.m4a',
    'M800wrongMid.mp3',
  ]) {
    test(
      'does not accept a downgrade, trial or wrong file: $filename',
      () async {
        http.reply = (_) async => moduleResponse({
          'midurlinfo': [
            {'result': 0, 'purl': filename},
          ],
          'sip': ['https://media.example/'],
        });
        final api = testClient(http, clock);
        addTearDown(api.close);
        await expectLater(
          api.resolve(parseQqTrack(songJson()), OnlineQuality.high),
          throwsA(kind(OnlineErrorKind.unavailable)),
        );
        expect(http.requests.length, 1);
      },
    );
  }

  test(
    'empty playback ticket does not probe another quality or endpoint',
    () async {
      http.reply = (_) async => moduleResponse({
        'midurlinfo': [
          {'result': 0, 'purl': ''},
        ],
      });
      final api = testClient(http, clock);
      addTearDown(api.close);
      await expectLater(
        api.resolve(parseQqTrack(songJson()), OnlineQuality.lossless),
        throwsA(kind(OnlineErrorKind.unavailable)),
      );
      expect(http.requests.length, 1);
    },
  );

  test('failed vkey rows are rejected without probing another tier', () async {
    http.reply = (_) async => moduleResponse({
      'midurlinfo': [
        {
          'result': 1,
          'songmid': 'songMid001',
          'purl': 'M800media001.mp3?vkey=trial',
        },
      ],
      'sip': ['https://media.example/'],
    });
    final api = testClient(http, clock);
    addTearDown(api.close);
    await expectLater(
      api.resolve(parseQqTrack(songJson()), OnlineQuality.high),
      throwsA(kind(OnlineErrorKind.unavailable)),
    );
    expect(http.requests.length, 1);
  });

  for (final retryAfter in [
    '300',
    HttpDate.format(DateTime.utc(2026, 11, 21, 0, 5)),
  ]) {
    test(
      'HTTP retry-after stops cross-operation traffic: $retryAfter',
      () async {
        http.reply = (_) async =>
            jsonResponse({}, status: 429, retryAfter: retryAfter);
        final api = testClient(http, clock);
        addTearDown(api.close);
        await expectLater(
          api.search('Song'),
          throwsA(kind(OnlineErrorKind.rateLimited)),
        );
        clock.advance(const Duration(minutes: 4));
        await expectLater(
          api.detail('songMid001'),
          throwsA(kind(OnlineErrorKind.rateLimited)),
        );
        expect(http.requests.length, 1);
      },
    );
  }

  test(
    'provider rejection halts queue without trying a compatibility API',
    () async {
      http.reply = (_) async => moduleResponse({}, code: 2000);
      final api = testClient(http, clock);
      addTearDown(api.close);
      await expectLater(
        api.detail('songMid001'),
        throwsA(kind(OnlineErrorKind.rejected)),
      );
      await expectLater(
        api.search('Other'),
        throwsA(kind(OnlineErrorKind.rejected)),
      );
      expect(http.requests.length, 1);
    },
  );

  test(
    'an HTML challenge pauses source-wide requests even with status 200',
    () async {
      http.reply = (_) async =>
          QqHttpResponse(statusCode: 200, body: '<html>challenge</html>');
      final api = testClient(http, clock);
      addTearDown(api.close);
      await expectLater(
        api.search('Song'),
        throwsA(kind(OnlineErrorKind.rejected)),
      );
      await expectLater(
        api.search('Other'),
        throwsA(kind(OnlineErrorKind.rejected)),
      );
      expect(http.requests.length, 1);
    },
  );

  test(
    'close prevents further requests and sanitized failures reveal no URL',
    () async {
      http.reply = (_) async => throw StateError('secret cookie or URL');
      final api = testClient(http, clock);
      try {
        await api.search('Song');
        fail('Expected request failure');
      } on OnlineException catch (error) {
        expect('$error', isNot(contains('secret')));
      }
      api.close();
      expect(http.closed, isTrue);
      await expectLater(
        api.search('Later'),
        throwsA(kind(OnlineErrorKind.closed)),
      );
      expect(http.requests.length, 1);
    },
  );
}

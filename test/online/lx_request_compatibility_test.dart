import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/lx/lx_http_connection.dart';
import 'package:motif/online/lx/lx_network.dart';
import 'package:motif/online/lx/lx_request_error.dart';

LxApiRequest request([Map<String, Object?> options = const {}]) =>
    LxApiRequest.parse({
      'url': 'https://api.example.test/lookup',
      'options': options,
    });

void main() {
  test('LX Mobile API timeout is 13s by default and honors up to 60s', () {
    for (final (input, ms) in <(Object?, int)>[
      (null, 13000),
      (0, 13000),
      (-1, 13000),
      ('12000', 13000),
      (1200, 1200),
      (10000, 10000),
      (12000, 12000),
      (60000, 60000),
      (90000, 60000),
    ]) {
      expect(request({'timeout': input}).timeout.inMilliseconds, ms);
    }
    expect(
      lxWireTimeout,
      const Duration(seconds: 6),
      reason: 'non-script media/catalog unchanged',
    );
  });

  test('a response beyond the old six-second cap completes within the bounded request budget', () async {
    final body = _Body(utf8.encode('ok'));
    final transport = LxHttpsTransport(
      open: (_, _, _, _, scope) async {
        await scope.until(
          Future<void>.delayed(const Duration(milliseconds: 6200)),
        );
        return (
          status: 200,
          reason: 'OK',
          headers: {
            'content-length': ['2'],
          },
          body: body,
        );
      },
    );
    expect((await transport.api(request(), PcmCancellation()))['body'], 'ok');
    expect(body.closed, isTrue);
  });

  test('request timeout is distinguished from user cancellation without exposing the URL', () async {
    final transport = LxHttpsTransport(
      open: (_, _, _, _, scope) async {
        return scope.until(Completer<LxWireResponse>().future);
      },
    );
    await expectLater(
      transport.api(request({'timeout': 20}), PcmCancellation()),
      throwsA(
        isA<LxRequestException>().having(
          (error) => error.reason,
          'reason',
          LxRequestFailure.timeout,
        ),
      ),
    );
    expect(
      const LxRequestException(LxRequestFailure.timeout).toString(),
      isNot(contains('https:')),
    );
  });

  test('DNS, connection and TLS failures survive the transport without becoming a generic error', () async {
    for (final reason in [
      LxRequestFailure.dns,
      LxRequestFailure.connect,
      LxRequestFailure.tls,
    ]) {
      final transport = LxHttpsTransport(
        open: (_, _, _, _, _) async => throw LxRequestException(reason),
      );
      await expectLater(
        transport.api(request(), PcmCancellation()),
        throwsA(
          isA<LxRequestException>()
              .having((error) => error.reason, 'reason', reason)
              .having((error) => error.kind, 'kind', OnlineErrorKind.transport),
        ),
      );
    }
  });

  test('LX headers retain script values and common defaults without application credentials', () {
    final parsed = request({
      'headers': {
        'Referer': 'https://music.example.test/player?id=42#fragment',
        'Origin': 'https://music.example.test',
        'X-Request-Key': 'fixture-key',
        'X-Requested-With': 'XMLHttpRequest',
      },
    });
    expect(
      parsed.headers['referer'],
      'https://music.example.test/player?id=42',
    );
    expect(parsed.headers['origin'], 'https://music.example.test');
    expect(parsed.headers['x-request-key'], 'fixture-key');
    expect(parsed.headers['accept'], 'application/json');
    expect(parsed.headers['user-agent'], contains('Mozilla/5.0'));
    expect(parsed.headers, isNot(contains('cookie')));
    expect(parsed.headers, isNot(contains('authorization')));
  });

  test('standard HTTP hostnames upgrade before dialing while unsafe authorities stay rejected', () {
    expect(
      checkedLxUrl('http://audio.example.test/song.mp3?key=fixture'),
      Uri.parse('https://audio.example.test/song.mp3?key=fixture'),
    );
    for (final raw in [
      'http://127.0.0.1/track',
      'http://8.8.8.8/track',
      'http://api.example.test:81/track',
      'http://user@api.example.test/track',
      'https://api.example.test/track#fragment',
      'https://api.example.test\\other/track',
    ]) {
      expect(checkedLxUrl(raw), isNull);
    }
  });

  test(
    'routing, account and injected header values remain unavailable to scripts',
    () {
      for (final headers in [
        {'Host': 'other.example.test'},
        {'Cookie': 'fixture=only'},
        {'Authorization': 'fixture-only'},
        {'Proxy-Authorization': 'fixture-only'},
        {'Transfer-Encoding': 'chunked'},
        {'X-Key': 'a\r\nHost: other.example.test'},
        {'bad header': 'value'},
        {'Origin': 'https://user:pass@music.example.test'},
      ]) {
        expect(
          () => request({'headers': headers}),
          throwsA(
            isA<LxRequestException>().having(
              (error) => error.reason,
              'reason',
              LxRequestFailure.headers,
            ),
          ),
        );
      }
    },
  );

  test(
    'form uses the LX component encoding and preserves empty or null fields',
    () {
      final parsed = request({
        'method': 'post',
        'form': {'name': 'a b+c', 'empty': '', 'none': null},
      });
      expect(utf8.decode(parsed.body!), 'name=a%20b%2Bc&empty=&none=null');
      expect(
        parsed.headers['content-type'],
        'application/x-www-form-urlencoded',
      );
    },
  );

  test('multipart has real boundaries and scalar fields, never native file locators', () {
    final parsed = request({
      'method': 'POST',
      'formData': {'song': '测试', 'quality': 128},
    });
    final type = parsed.headers['content-type']!;
    final boundary = type.split('boundary=').last;
    final body = utf8.decode(parsed.body!);
    expect(
      body,
      startsWith(
        '--$boundary\r\nContent-Disposition: form-data; name="song"\r\n\r\n测试\r\n',
      ),
    );
    expect(body, endsWith('--$boundary--\r\n'));
    expect(
      () => request({
        'method': 'POST',
        'formData': {
          'file': {'uri': 'file:///private'},
        },
      }),
      throwsA(isA<LxRequestException>()),
    );
  });

  test('byte request bodies preserve the LX Buffer representation', () {
    final parsed = request({
      'method': 'POST',
      'body': {
        'type': 'Buffer',
        'data': [0, 128, 255],
      },
    });
    expect(parsed.body, [0, 128, 255]);
    expect(
      () => request({
        'method': 'POST',
        'body': {
          'type': 'Buffer',
          'data': [256],
        },
      }),
      throwsA(isA<LxRequestException>()),
    );
  });

  test('JSON or text callbacks preserve response headers while excluding cookie storage', () async {
    final body = _Body(
      utf8.encode('{"url":"https://cdn.example.test/test.mp3"}'),
    );
    final transport = LxHttpsTransport(
      open: (_, _, _, _, _) async => (
        status: 200,
        reason: 'OK',
        headers: {
          'content-length': ['${body.bytes.length}'],
          'x-source-version': ['fixture'],
          'set-cookie': ['fixture-only'],
        },
        body: body,
      ),
    );
    final result = await transport.api(request(), PcmCancellation());
    expect(result['body'], {'url': 'https://cdn.example.test/test.mp3'});
    expect(result['headers'], {
      'content-length': '${body.bytes.length}',
      'x-source-version': 'fixture',
    });
    expect(body.closed, isTrue);
  });

  test(
    'binary response bytes cross IPC as bounded base64 without text corruption',
    () async {
      final body = _Body([0, 128, 255, 13, 10]);
      final transport = LxHttpsTransport(
        open: (_, _, _, _, _) async => (
          status: 200,
          reason: 'OK',
          headers: {
            'content-length': ['5'],
          },
          body: body,
        ),
      );
      final result = await transport.api(
        request({'binary': true}),
        PcmCancellation(),
      );
      expect(result['_binary'], isTrue);
      expect(result['body'], isNull);
      expect(base64Decode(result['_rawBase64'] as String), body.bytes);
      expect(body.closed, isTrue);
    },
  );

  test('desktop raw and parsed response describe the same bytes', () async {
    final body = _Body(utf8.encode('{"ok":true}'));
    final transport = LxHttpsTransport(
      open: (_, _, _, _, _) async => (
        status: 200,
        reason: 'OK',
        headers: {
          'content-length': ['${body.bytes.length}'],
        },
        body: body,
      ),
    );
    final result = await transport.api(
      request({'_responseBytes': true}),
      PcmCancellation(),
    );
    expect(result['body'], {'ok': true});
    expect(base64Decode(result['_rawBase64'] as String), body.bytes);
  });

  test('mobile redirects upgrade HTTP and do not forward source keys to another host', () async {
    final calls = <(Uri, String, Map<String, String>, Uint8List?)>[];
    final bodies = <_Body>[];
    var redirects = 0;
    final parsed = LxApiRequest.parse(
      {
        'url': 'https://api.example.test/start',
        'options': {
          'method': 'POST',
          'body': {'song': 42},
          'headers': {'X-Request-Key': 'fixture-only'},
        },
      },
      onRedirect: () {
        redirects++;
      },
    );
    final transport = LxHttpsTransport(
      open: (uri, method, headers, data, _) async {
        calls.add((uri, method, Map.of(headers), data));
        final body = _Body(utf8.encode(calls.length == 1 ? '' : 'done'));
        bodies.add(body);
        return (
          status: calls.length == 1 ? 302 : 200,
          reason: 'Fixture',
          headers: calls.length == 1
              ? {
                  'location': ['http://other.example.test/result'],
                }
              : {
                  'content-length': ['4'],
                },
          body: body,
        );
      },
    );
    expect((await transport.api(parsed, PcmCancellation()))['body'], 'done');
    expect(calls.last.$1, Uri.parse('https://other.example.test/result'));
    expect(calls.last.$2, 'GET');
    expect(calls.last.$3, isNot(contains('x-request-key')));
    expect(calls.last.$4, isNull);
    expect(redirects, 1);
    expect(bodies.every((body) => body.closed), isTrue);
  });

  test(
    'private redirect targets and redirect loops are still bounded per request',
    () async {
      for (final location in ['https://127.0.0.1/track', '/repeat']) {
        var calls = 0;
        final body = _Body([]);
        final parsed = LxApiRequest.parse({
          'url': 'https://api.example.test/start',
          'options': <String, Object?>{},
        });
        final transport = LxHttpsTransport(
          open: (_, _, _, _, _) async {
            calls++;
            return (
              status: 302,
              reason: 'Fixture',
              headers: {
                'location': [location],
              },
              body: body,
            );
          },
        );
        await expectLater(
          transport.api(parsed, PcmCancellation()),
          throwsA(isA<LxRequestException>()),
        );
        expect(calls, location == '/repeat' ? 4 : 1);
        expect(body.closed, isTrue);
      }
    },
  );

  test('desktop can preserve a redirect response for the script', () async {
    var calls = 0;
    final transport = LxHttpsTransport(
      open: (_, _, _, _, _) async {
        calls++;
        return (
          status: 302,
          reason: 'Found',
          headers: {
            'content-length': ['0'],
            'location': ['/next'],
          },
          body: _Body([]),
        );
      },
    );
    final result = await transport.api(
      request({'_followRedirects': false}),
      PcmCancellation(),
    );
    expect(result['statusCode'], 302);
    expect(calls, 1);
  });

  test(
    'a redirect cannot send a script request body to another origin',
    () async {
      var calls = 0;
      final body = _Body([]);
      final transport = LxHttpsTransport(
        open: (_, _, _, _, _) async {
          calls++;
          return (
            status: 307,
            reason: 'Temporary redirect',
            headers: {
              'location': ['https://other.example.test/next'],
            },
            body: body,
          );
        },
      );
      await expectLater(
        transport.api(
          request({
            'method': 'POST',
            'body': {'key': 'fixture-only'},
          }),
          PcmCancellation(),
        ),
        throwsA(isA<LxRequestException>()),
      );
      expect(calls, 1);
      expect(body.closed, isTrue);
    },
  );

  test('mixed DNS answers pin a public address and never select the private alternative', () {
    expect(
      selectLxPublicAddress([
        InternetAddress('198.18.0.1'),
        InternetAddress('8.8.8.8'),
      ]).address,
      '8.8.8.8',
    );
    expect(
      () => selectLxPublicAddress([
        InternetAddress('127.0.0.1'),
        InternetAddress('192.168.1.1'),
      ]),
      throwsA(
        isA<LxRequestException>().having(
          (error) => error.reason,
          'reason',
          LxRequestFailure.privateAddress,
        ),
      ),
    );
  });

  test(
    'request cancellation ends an in-flight exchange without a late result',
    () async {
      final cancellation = PcmCancellation();
      final started = Completer<void>();
      final transport = LxHttpsTransport(
        open: (_, _, _, _, scope) async {
          started.complete();
          return scope.until(Completer<LxWireResponse>().future);
        },
      );
      final future = transport.api(request(), cancellation);
      final assertion = expectLater(future, throwsA(isA<PcmCancelled>()));
      await started.future;
      cancellation.cancel();
      await assertion;
    },
  );
}

final class _Body implements LxWireBody {
  _Body(List<int> value) : bytes = Uint8List.fromList(value);
  final Uint8List bytes;
  var offset = 0;
  bool closed = false;
  @override
  Future<Uint8List> read(int maximum) async {
    if (closed) throw const PcmCancelled();
    final end = (offset + maximum).clamp(offset, bytes.length);
    final result = Uint8List.sublistView(bytes, offset, end);
    offset = end;
    return result;
  }

  @override
  Future<String> readLine(int limit) async {
    final start = offset;
    while (offset + 1 < bytes.length && offset - start < limit) {
      if (bytes[offset] == 13 && bytes[offset + 1] == 10) {
        final text = ascii.decode(bytes.sublist(start, offset));
        offset += 2;
        return text;
      }
      offset++;
    }
    throw const FormatException('Fixture line');
  }

  @override
  void close() => closed = true;
}

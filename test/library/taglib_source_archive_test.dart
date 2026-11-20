import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../packages/motif_taglib/hook/source_archive.dart';
import '../support/library_fixtures.dart';

void main() {
  final payload = utf8.encode('pinned source archive\n');
  const digest =
      '2b2f070485ce8706a93cc9b806f9544b1d13c70e9cb69c136816355208c0b444';
  late Directory directory;
  late File cache;
  late HttpServer server;
  late Uri source;
  late Future<void> Function(HttpRequest) respond;
  late int requests;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('motif-source-archive-');
    cache = File.fromUri(directory.uri.resolve('source.zip'));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source = Uri.parse('http://127.0.0.1:${server.port}/source.zip');
    requests = 0;
    respond = (request) async {
      request.response.add(payload);
      await request.response.close();
    };
    server.listen((request) async {
      requests++;
      await respond(request);
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await deleteTestDirectory(directory);
  });

  Future<List<int>> load() => loadVerifiedSourceArchive(
    cache: cache,
    source: source,
    expectedSha256: digest,
  );

  Future<void> expectOnlyCache(List<int> bytes) async {
    expect(await cache.readAsBytes(), bytes);
    expect(await directory.list().map((entry) => entry.path).toList(), [
      cache.path,
    ]);
  }

  test(
    'downloads and caches only a source matching the pinned digest',
    () async {
      expect(await load(), payload);
      expect(requests, 1);
      await expectOnlyCache(payload);
    },
  );

  test('a verified cache is reusable without a network request', () async {
    await cache.writeAsBytes(payload);
    respond = (request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    };
    expect(await load(), payload);
    expect(requests, 0);
    await expectOnlyCache(payload);
  });

  test(
    'an existing partial cache is repaired from a verified download',
    () async {
      await cache.writeAsBytes(payload.take(4).toList());
      expect(await load(), payload);
      expect(requests, 1);
      await expectOnlyCache(payload);
    },
  );

  test(
    'a checksum mismatch leaves no cache and a later request can succeed',
    () async {
      respond = (request) async {
        request.response.add(utf8.encode('untrusted payload'));
        await request.response.close();
      };
      await expectLater(load(), throwsStateError);
      expect(await directory.list().toList(), isEmpty);
      respond = (request) async {
        request.response.add(payload);
        await request.response.close();
      };
      expect(await load(), payload);
      expect(requests, 2);
      await expectOnlyCache(payload);
    },
  );

  test('a truncated transfer leaves no cache and can be retried', () async {
    respond = (request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: ${payload.length}\r\n'
        'Connection: close\r\n\r\n',
      );
      socket.add(payload.take(4).toList());
      await socket.flush();
      socket.destroy();
    };
    await expectLater(load(), throwsA(isA<HttpException>()));
    expect(await directory.list().toList(), isEmpty);
    respond = (request) async {
      request.response.add(payload);
      await request.response.close();
    };
    expect(await load(), payload);
    expect(requests, 2);
    await expectOnlyCache(payload);
  });

  test(
    'an in-progress repair leaves the old cache unchanged until verification',
    () async {
      final oldBytes = utf8.encode('partial old cache');
      await cache.writeAsBytes(oldBytes);
      final started = Completer<void>();
      final finish = Completer<void>();
      respond = (request) async {
        request.response.contentLength = payload.length;
        request.response.add(payload.take(4).toList());
        await request.response.flush();
        started.complete();
        await finish.future;
        request.response.add(payload.skip(4).toList());
        await request.response.close();
      };
      final loading = load();
      try {
        await started.future;
        expect(await cache.readAsBytes(), oldBytes);
      } finally {
        finish.complete();
        await loading;
      }
      expect(requests, 1);
      await expectOnlyCache(payload);
    },
  );

  test('an empty successful HTTP response cannot become a cache', () async {
    respond = (request) async {
      await request.response.close();
    };
    await expectLater(load(), throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });

  test('an HTTP error leaves no cache or temporary files', () async {
    respond = (request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.add(payload);
      await request.response.close();
    };
    await expectLater(load(), throwsA(isA<HttpException>()));
    expect(requests, 1);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'a failed repair preserves the old bytes and cleans temporary files',
    () async {
      final partial = payload.take(4).toList();
      await cache.writeAsBytes(partial);
      respond = (request) async {
        request.response.add(utf8.encode('untrusted replacement'));
        await request.response.close();
      };
      await expectLater(load(), throwsStateError);
      expect(requests, 1);
      await expectOnlyCache(partial);
    },
  );
}

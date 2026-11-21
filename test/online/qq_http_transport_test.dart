import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/network/qq_http_transport.dart';

import 'request_coordinator_test.dart' show kind;

class FakeHeaders extends Fake implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  set contentType(ContentType? type) {
    if (type != null) values['content-type'] = type;
  }

  @override
  String? value(String name) => values[name]?.toString();
}

class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(this.chunks, {this.statusCode = 200, this.contentLength = -1});
  final List<List<int>> chunks;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final headers = FakeHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRequest extends Fake implements HttpClientRequest {
  FakeRequest(this.response);
  final HttpClientResponse response;
  bool aborted = false;
  int sends = 0;
  Object? body;
  @override
  bool followRedirects = true;
  @override
  final headers = FakeHeaders();
  @override
  void write(Object? object) => body = object;
  @override
  Future<HttpClientResponse> close() async {
    sends++;
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
}

class FakeClient extends Fake implements HttpClient {
  FakeClient(this.openRequest);
  final Future<HttpClientRequest> Function() openRequest;
  bool closed = false;
  int opens = 0;
  String? method;
  @override
  Duration? connectionTimeout;
  @override
  int? maxConnectionsPerHost = 0;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    opens++;
    this.method = method;
    return openRequest();
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  final endpoint = Uri.parse('https://u.y.qq.com/cgi-bin/musicu.fcg');
  test(
    'POST is bounded, JSON encoded, anonymous and does not follow redirects',
    () async {
      final request = FakeRequest(FakeResponse([utf8.encode('{"code":0}')]));
      final client = FakeClient(() async => request);
      final http = IoQqHttpTransport(client: client);
      addTearDown(http.close);
      final response = await http.send(
        QqHttpRequest(uri: endpoint, jsonBody: {'test': 1}),
      );
      expect(client.method, 'POST');
      expect(client.maxConnectionsPerHost, 1);
      expect(request.followRedirects, isFalse);
      expect(jsonDecode(request.body! as String), {'test': 1});
      expect(
        (request.headers as FakeHeaders).values.keys,
        isNot(contains('cookie')),
      );
      expect(response.body, '{"code":0}');
    },
  );

  test(
    'unapproved hosts, schemes, ports and credentials are rejected before open',
    () async {
      final client = FakeClient(() async => throw StateError('Must not open'));
      final http = IoQqHttpTransport(client: client);
      addTearDown(http.close);
      for (final raw in [
        'http://u.y.qq.com/',
        'https://example.org/',
        'https://u.y.qq.com:8443/',
        'https://user:password@u.y.qq.com/',
      ]) {
        await expectLater(
          http.send(QqHttpRequest(uri: Uri.parse(raw))),
          throwsA(kind(OnlineErrorKind.unsupported)),
        );
      }
      expect(client.opens, 0);
    },
  );

  test(
    'declared and streamed oversized responses abort without retaining them',
    () async {
      for (final response in [
        FakeResponse([], contentLength: 100),
        FakeResponse([
          [1, 2, 3],
          [4, 5, 6],
        ]),
      ]) {
        final request = FakeRequest(response);
        final http = IoQqHttpTransport(
          client: FakeClient(() async => request),
          maxResponseBytes: 5,
        );
        await expectLater(
          http.send(QqHttpRequest(uri: endpoint)),
          throwsA(kind(OnlineErrorKind.malformedResponse)),
        );
        expect(request.aborted, isTrue);
        http.close();
      }
    },
  );

  test(
    '429 preserves retry-after and does not download a challenge body',
    () async {
      final response = FakeResponse([
        [255],
      ], statusCode: 429);
      (response.headers as FakeHeaders).values['retry-after'] = '300';
      final request = FakeRequest(response);
      final http = IoQqHttpTransport(client: FakeClient(() async => request));
      addTearDown(http.close);
      final result = await http.send(QqHttpRequest(uri: endpoint));
      expect(result.statusCode, 429);
      expect(result.retryAfter, '300');
      expect(result.body, isEmpty);
      expect(request.aborted, isTrue);
    },
  );

  test('timed-out late open is aborted before any HTTP send', () async {
    final pending = Completer<HttpClientRequest>();
    final request = FakeRequest(FakeResponse([]));
    final http = IoQqHttpTransport(
      client: FakeClient(() => pending.future),
      timeout: const Duration(milliseconds: 5),
    );
    addTearDown(http.close);
    await expectLater(
      http.send(QqHttpRequest(uri: endpoint)),
      throwsA(kind(OnlineErrorKind.transport)),
    );
    pending.complete(request);
    await Future<void>.delayed(Duration.zero);
    expect(request.aborted, isTrue);
    expect(request.sends, 0);
  });

  test('closed client admits no more requests', () async {
    final client = FakeClient(() async => throw StateError('Must not open'));
    final http = IoQqHttpTransport(client: client);
    http.close();
    await expectLater(
      http.send(QqHttpRequest(uri: endpoint)),
      throwsA(kind(OnlineErrorKind.closed)),
    );
    expect(client.closed, isTrue);
    expect(client.opens, 0);
  });
}

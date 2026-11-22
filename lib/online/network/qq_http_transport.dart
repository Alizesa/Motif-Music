import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/online_error.dart';

class QqHttpRequest {
  QqHttpRequest({
    required this.uri,
    this.jsonBody,
    this.userAgent,
    this.origin,
  });
  final Uri uri;
  final String? userAgent;
  final String? origin;
  final Map<String, Object?>? jsonBody;
}

class QqHttpResponse {
  QqHttpResponse({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });
  final int statusCode;
  final String body;
  final String? retryAfter;
}

abstract interface class QqHttpTransport {
  Future<QqHttpResponse> send(QqHttpRequest request);
  void close();
}

/// Public, anonymous QQ API traffic only; cookies never enter this transport.
class IoQqHttpTransport implements QqHttpTransport {
  IoQqHttpTransport({
    HttpClient? client,
    this.timeout = const Duration(seconds: 12),
    this.maxResponseBytes = 2 * 1024 * 1024,
  }) : _client = client ?? HttpClient() {
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Invalid HTTP limits');
    }
    _client.connectionTimeout = timeout;
    _client.maxConnectionsPerHost = 1;
    _client.userAgent = 'Motif/0.1';
  }

  final HttpClient _client;
  final Duration timeout;
  final int maxResponseBytes;
  bool _closed = false;

  @override
  Future<QqHttpResponse> send(QqHttpRequest request) async {
    if (_closed) throw const OnlineException(OnlineErrorKind.closed);
    final uri = request.uri;
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment ||
        !{'c.y.qq.com', 'u.y.qq.com'}.contains(uri.host)) {
      throw const OnlineException(OnlineErrorKind.unsupported);
    }
    HttpClientRequest? active;
    var cancelled = false;
    try {
      return await (() async {
        final outgoing = active = await _client.openUrl(
          request.jsonBody == null ? 'GET' : 'POST',
          uri,
        );
        if (cancelled || _closed) {
          outgoing.abort();
          throw const OnlineException(OnlineErrorKind.transport);
        }
        outgoing.followRedirects = false;
        outgoing.headers.set(
          HttpHeaders.acceptHeader,
          'application/json, text/plain, */*',
        );
        if (request.userAgent != null) {
          outgoing.headers.set(HttpHeaders.userAgentHeader, request.userAgent!);
        }
        outgoing.headers.set(HttpHeaders.refererHeader, 'https://y.qq.com/');
        if (request.origin != null) {
          outgoing.headers.set('origin', request.origin!);
        }
        if (request.jsonBody != null) {
          outgoing.headers.contentType = ContentType.json;
          outgoing.write(jsonEncode(request.jsonBody));
        }
        final response = await outgoing.close();
        final retryAfter = response.headers.value(HttpHeaders.retryAfterHeader);
        if (response.statusCode != HttpStatus.ok) {
          // Do not download an HTML error/challenge or follow its redirects.
          outgoing.abort();
          return QqHttpResponse(
            statusCode: response.statusCode,
            body: '',
            retryAfter: retryAfter,
          );
        }
        if (response.contentLength > maxResponseBytes) {
          throw const OnlineException(OnlineErrorKind.malformedResponse);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const OnlineException(OnlineErrorKind.malformedResponse);
          }
          bytes.addAll(chunk);
        }
        return QqHttpResponse(
          statusCode: response.statusCode,
          body: utf8.decode(bytes),
          retryAfter: retryAfter,
        );
      })().timeout(timeout);
    } on OnlineException {
      cancelled = true;
      active?.abort();
      rethrow;
    } catch (_) {
      cancelled = true;
      active?.abort();
      throw const OnlineException(OnlineErrorKind.transport);
    }
  }

  @override
  void close() {
    _closed = true;
    _client.close(force: true);
  }
}

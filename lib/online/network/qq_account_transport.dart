import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../qq/auth/qq_auth_error.dart';
import '../qq/auth/qq_credential.dart';

class QqAccountRequest {
  const QqAccountRequest({
    required this.uri,
    this.cookie = '',
    this.referer = 'https://y.qq.com/',
    this.userAgent = 'QQMusic 14090008(android 14)',
    this.jsonBody,
    this.form,
  });
  final Uri uri;
  final String cookie;
  final String referer;
  final String userAgent;
  final Map<String, Object?>? jsonBody;
  final Map<String, String>? form;
  @override
  String toString() => 'QqAccountRequest(redacted)';
}

class QqAccountResponse {
  const QqAccountResponse({
    required this.status,
    required this.bytes,
    this.setCookies = const [],
    this.location,
  });
  final int status;
  final Uint8List bytes;
  final List<String> setCookies;
  final String? location;
  String get text => utf8.decode(bytes);
  String get cookie => qqCookieHeader({
    for (final raw in setCookies) ...qqCookieValues(raw.split(';').first),
  });
  @override
  String toString() => 'QqAccountResponse(status: $status, redacted)';
}

abstract interface class QqAccountTransport {
  Future<QqAccountResponse> send(QqAccountRequest request);
  void close();
}

/// Cookies are explicit per request, never an automatic cross-host cookie jar.
/// Redirects are returned to the protocol client for origin/path validation.
class IoQqAccountTransport implements QqAccountTransport {
  IoQqAccountTransport({
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
    this.maxBytes = 2097152,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
    _client.maxConnectionsPerHost = 2;
  }
  final HttpClient _client;
  final Duration timeout;
  final int maxBytes;
  bool _closed = false;
  static const hosts = {
    'u.y.qq.com',
    'c.y.qq.com',
    'y.qq.com',
    'ssl.ptlogin2.qq.com',
    'ssl.ptlogin2.graph.qq.com',
    'graph.qq.com',
    'open.weixin.qq.com',
    'lp.open.weixin.qq.com',
  };

  @override
  Future<QqAccountResponse> send(QqAccountRequest request) async {
    final uri = request.uri;
    if (_closed) throw const QqAuthException(QqAuthErrorKind.cancelled);
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !hosts.contains(uri.host)) {
      throw const QqAuthException(QqAuthErrorKind.rejected);
    }
    HttpClientRequest? active;
    var abandoned = false;
    try {
      return await (() async {
        final outgoing = active = await _client.openUrl(
          request.jsonBody != null || request.form != null ? 'POST' : 'GET',
          uri,
        );
        if (_closed || abandoned) {
          outgoing.abort();
          throw const QqAuthException(QqAuthErrorKind.cancelled);
        }
        outgoing.followRedirects = false;
        outgoing.headers.set(HttpHeaders.refererHeader, request.referer);
        outgoing.headers.set(HttpHeaders.userAgentHeader, request.userAgent);
        final cookie = qqCookieHeader(qqCookieValues(request.cookie));
        if (cookie.isNotEmpty) {
          outgoing.headers.set(HttpHeaders.cookieHeader, cookie);
        }
        if (request.jsonBody != null) {
          outgoing.headers.contentType = ContentType.json;
          outgoing.write(jsonEncode(request.jsonBody));
        } else if (request.form != null) {
          outgoing.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
            charset: 'utf-8',
          );
          outgoing.write(Uri(queryParameters: request.form).query);
        }
        final response = await outgoing.close();
        final cookies =
            response.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (response.statusCode >= 300 && response.statusCode < 400) {
          outgoing.abort();
          return QqAccountResponse(
            status: response.statusCode,
            bytes: Uint8List(0),
            setCookies: cookies,
            location: location,
          );
        }
        if (response.contentLength > maxBytes) {
          throw const QqAuthException(QqAuthErrorKind.malformed);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const QqAuthException(QqAuthErrorKind.malformed);
          }
          bytes.add(chunk);
        }
        return QqAccountResponse(
          status: response.statusCode,
          bytes: bytes.takeBytes(),
          setCookies: cookies,
          location: location,
        );
      })().timeout(timeout);
    } on QqAuthException {
      abandoned = true;
      active?.abort();
      rethrow;
    } catch (_) {
      abandoned = true;
      active?.abort();
      throw QqAuthException(
        _closed ? QqAuthErrorKind.cancelled : QqAuthErrorKind.transport,
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

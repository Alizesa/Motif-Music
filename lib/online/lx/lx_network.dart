import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../audio/controlled_pcm.dart';
import '../domain/online_error.dart';
import 'fixture/lx_fixture_wave.dart';
import 'lx_http_connection.dart';

export 'lx_http_connection.dart' show isPublicLxAddress;

const _transportBudget = lxWireTimeout;
const _apiBodyLimit = 48 * 1024;

String? lxHost(String value) {
  final host = value.trim().toLowerCase();
  if (host.length > 253 || InternetAddress.tryParse(host) != null) return null;
  final labels = host.split('.');
  final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (labels.length < 2 ||
      !RegExp(r'^[a-z]').hasMatch(labels.last) ||
      !labels.every(label.hasMatch)) {
    return null;
  }
  return host;
}

Uri? checkedLxUrl(Object? raw) {
  if (raw is! String ||
      raw.length > 2048 ||
      RegExp(r'[\x00-\x20\x7f\\]').hasMatch(raw)) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  return uri != null &&
          uri.scheme == 'https' &&
          uri.port == 443 &&
          !uri.authority.contains('@') &&
          !uri.hasFragment &&
          lxHost(uri.host) == uri.host
      ? uri
      : null;
}

final class LxApiRequest {
  const LxApiRequest._(
    this.uri,
    this.method,
    this.headers,
    this.body,
    this.timeout,
  );
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final Uint8List? body;
  final Duration timeout;

  static LxApiRequest parse(Map<String, Object?> message) {
    final uri = checkedLxUrl(message['url']);
    if (uri == null) {
      throw const OnlineException(OnlineErrorKind.rejected);
    }
    final options = message['options'];
    if (options is! Map) throw const FormatException('LX options');
    final verb = options['method'] ?? 'GET';
    if (verb is! String) throw const FormatException('LX method');
    final method = verb.toUpperCase();
    if (!const {'GET', 'HEAD', 'POST'}.contains(method) ||
        options['binary'] == true ||
        options['formData'] != null) {
      throw const OnlineException(OnlineErrorKind.unsupported);
    }
    final headers = <String, String>{};
    final supplied = options['headers'];
    if (supplied != null && supplied is! Map) {
      throw const FormatException('LX headers');
    }
    for (final entry in (supplied as Map? ?? const {}).entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          (value is! String && value is! num) ||
          headers.length >= 8 ||
          !const {
            'accept',
            'accept-language',
            'user-agent',
            'content-type',
          }.contains(name.toLowerCase()) ||
          !RegExp(r'^[\x20-\x7e]{1,512}$').hasMatch(value.toString())) {
        throw const OnlineException(OnlineErrorKind.rejected);
      }
      headers[name.toLowerCase()] = value.toString();
    }
    Uint8List? body;
    final value = options['body'];
    final form = options['form'];
    if (value != null || form != null) {
      if (method != 'POST' || (value != null && form != null)) {
        throw const FormatException('LX body');
      }
      if (form is Map) {
        final fields = <String>[];
        for (final entry in form.entries) {
          if (entry.key is! String ||
              (entry.value is! String &&
                  entry.value is! num &&
                  entry.value is! bool)) {
            throw const FormatException('LX form');
          }
          fields.add(
            '${Uri.encodeQueryComponent(entry.key as String)}='
            '${Uri.encodeQueryComponent(entry.value.toString())}',
          );
        }
        headers['content-type'] = 'application/x-www-form-urlencoded';
        body = utf8.encode(fields.join('&'));
      } else if (form != null) {
        throw const FormatException('LX form');
      } else if (value is String) {
        body = utf8.encode(value);
      } else {
        body = utf8.encode(jsonEncode(value));
        headers.putIfAbsent('content-type', () => 'application/json');
      }
      if (body.length > _apiBodyLimit) {
        throw const FormatException('LX body size');
      }
    }
    final wait = options['timeout'];
    final timeout = wait is num && wait.isFinite && wait > 0
        ? Duration(
            milliseconds: wait
                .clamp(1, _transportBudget.inMilliseconds)
                .round(),
          )
        : _transportBudget;
    return LxApiRequest._(uri, method, headers, body, timeout);
  }
}

/// Runs one host-checked public HTTPS exchange with a total deadline.
final class LxHttpsTransport {
  const LxHttpsTransport();

  Future<Map<String, Object?>> api(
    LxApiRequest request,
    PcmCancellation cancellation,
  ) async {
    final scope = PcmCancellation();
    final unlink = cancellation.listen(scope.cancel);
    final deadline = Timer(request.timeout, scope.cancel);
    LxWireResponse? reply;
    try {
      reply = await openLxHttps(
        request.uri,
        request.method,
        request.headers,
        request.body,
        scope,
      );
      if (reply.status == 429) {
        throw const OnlineException(OnlineErrorKind.rateLimited);
      }
      final encodings = reply.headers['content-encoding'];
      if (encodings != null &&
          (encodings.length != 1 ||
              encodings.single.toLowerCase() != 'identity')) {
        throw const OnlineException(OnlineErrorKind.malformedResponse);
      }
      final text = utf8.decode(await _readApiBody(reply, request.method));
      Object? value = text;
      try {
        value = jsonDecode(text);
      } on FormatException {
        // LX delivers text if its JSON parse fails.
      }
      return {
        'statusCode': reply.status,
        'statusMessage': reply.reason,
        'headers': {
          for (final entry in reply.headers.entries)
            if (const {
              'content-type',
              'content-length',
              'location',
              'etag',
              'retry-after',
            }.contains(entry.key))
              entry.key: entry.value.join(', '),
        },
        'body': value,
      };
    } on PcmCancelled {
      cancellation.check();
      throw const OnlineException(OnlineErrorKind.transport);
    } on FixtureMediaException catch (error) {
      cancellation.check();
      throw OnlineException(
        error.kind == FixtureMediaFailure.denied
            ? OnlineErrorKind.rejected
            : OnlineErrorKind.transport,
      );
    } finally {
      reply?.body.close();
      deadline.cancel();
      unlink();
    }
  }
}

Future<Uint8List> _readApiBody(LxWireResponse reply, String method) async {
  if (method == 'HEAD' || reply.status == 204 || reply.status == 304) {
    return Uint8List(0);
  }
  const invalid = OnlineException(OnlineErrorKind.malformedResponse);
  final body = reply.body;
  final transferred = reply.headers['transfer-encoding'];
  final lengths = reply.headers['content-length'];
  final buffer = BytesBuilder(copy: false);

  Future<void> readCount(int size) async {
    if (size < 0 || size + buffer.length > _apiBodyLimit) throw invalid;
    while (size != 0) {
      final part = await body.read(size.clamp(1, 8192));
      if (part.isEmpty) throw invalid;
      buffer.add(part);
      size -= part.length;
    }
  }

  if (transferred != null) {
    if (lengths != null ||
        transferred.length != 1 ||
        transferred.single.toLowerCase() != 'chunked') {
      throw invalid;
    }
    while (true) {
      final digits = (await body.readLine(256)).split(';').first;
      if (!RegExp(r'^[0-9a-fA-F]{1,8}$').hasMatch(digits)) throw invalid;
      final size = int.parse(digits, radix: 16);
      if (size == 0) break;
      await readCount(size);
      if ((await body.readLine(2)).isNotEmpty) throw invalid;
    }
  } else if (lengths != null) {
    if (lengths.length != 1 || !RegExp(r'^\d{1,9}$').hasMatch(lengths.single)) {
      throw invalid;
    }
    await readCount(int.parse(lengths.single));
  } else {
    while (true) {
      final part = await body.read(8192);
      if (part.isEmpty) break;
      if (buffer.length + part.length > _apiBodyLimit) throw invalid;
      buffer.add(part);
    }
  }
  return buffer.takeBytes();
}

typedef LxMediaOpen = Future<FixtureRangeResponse> Function(
  Uri uri,
  Map<String, String> headers,
  PcmCancellation cancellation,
);

Future<FixtureRangeResponse> _openMediaRange(
  Uri uri,
  Map<String, String> headers,
  PcmCancellation cancellation,
) async {
  final reply = await openLxHttps(uri, 'GET', headers, null, cancellation);
  return FixtureRangeResponse(
    status: reply.status,
    headers: reply.headers,
    body: reply.body,
  );
}

final class LxMediaTransport implements FixtureRangeTransport {
  LxMediaTransport(this.uri, this.owner, {LxMediaOpen? open})
    : _open = open ?? _openMediaRange;
  final Uri uri;
  final PcmCancellation owner;
  final LxMediaOpen _open;
  Uri? _representation;

  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async {
    final scope = PcmCancellation();
    final unlistenOwner = owner.listen(scope.cancel);
    final unlisten = cancellation.listen(scope.cancel);
    var next = _representation ?? uri;
    try {
      for (var hop = 0; hop <= 3; hop++) {
        scope.check();
        if (checkedLxUrl(next.toString()) == null) {
          throw const OnlineException(OnlineErrorKind.rejected);
        }
        final reply = await _open(next, {
          'accept': 'audio/wav, application/octet-stream',
          'range': 'bytes=$offset-',
          'if-range': ?validator,
        }, scope);
        if (!const {301, 302, 303, 307, 308}.contains(reply.status)) {
          if (offset == 0 && reply.status == 206) _representation = next;
          return FixtureRangeResponse(
            status: reply.status,
            headers: reply.headers,
            body: _RangeBody(reply.body, () {
              unlisten();
              unlistenOwner();
            }),
          );
        }
        reply.body.close();
        if (validator != null) break;
        final locations = reply.headers['location'];
        if (locations?.length != 1) break;
        next = next.resolve(locations!.single);
      }
      throw const OnlineException(OnlineErrorKind.rejected);
    } catch (_) {
      unlisten();
      unlistenOwner();
      scope.cancel();
      rethrow;
    }
  }
}

final class _RangeBody implements ControlledPcmRead {
  _RangeBody(this._body, this._release);
  final ControlledPcmRead _body;
  final void Function() _release;

  @override
  Future<Uint8List> read(int maximum) => _body.read(maximum);

  @override
  void close() {
    _release();
    _body.close();
  }
}

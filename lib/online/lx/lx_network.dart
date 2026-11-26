import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../audio/controlled_pcm.dart';
import '../domain/online_error.dart';
import 'fixture/lx_fixture_wave.dart';
import 'lx_http_connection.dart';
import 'lx_request_error.dart';

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
  var uri = Uri.tryParse(raw);
  if (uri != null &&
      uri.scheme == 'http' &&
      uri.port == 80 &&
      lxHost(uri.host) == uri.host) {
    uri = uri.replace(scheme: 'https', port: 443);
  }
  return uri != null &&
          uri.scheme == 'https' &&
          uri.port == 443 &&
          !uri.authority.contains('@') &&
          !uri.hasFragment &&
          lxHost(uri.host) == uri.host
      ? uri
      : null;
}

String _checkedWebHeader(String value, {required bool origin}) {
  if (origin && value == 'null') return value;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      lxHost(uri.host) != uri.host ||
      uri.port != (uri.scheme == 'https' ? 443 : 80) ||
      (origin &&
          ((uri.path.isNotEmpty && uri.path != '/') ||
              uri.hasQuery ||
              uri.hasFragment))) {
    throw const LxRequestException(LxRequestFailure.headers);
  }
  if (origin) return uri.origin;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}

final class LxApiRequest {
  const LxApiRequest._(
    this.uri,
    this.method,
    this.headers,
    this.body,
    this.timeout,
    this.binary,
    this.responseBytes,
    this.followRedirects,
    this.onRedirect,
  );
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final Uint8List? body;
  final Duration timeout;
  final bool binary;
  final bool responseBytes;
  final bool followRedirects;
  final void Function()? onRedirect;

  static LxApiRequest parse(
    Map<String, Object?> message, {
    void Function()? onRedirect,
  }) {
    final uri = checkedLxUrl(message['url']);
    if (uri == null) {
      throw const LxRequestException(LxRequestFailure.apiAddress);
    }
    final options = message['options'];
    if (options is! Map) throw const FormatException('LX options');
    final verb = options['method'] ?? 'GET';
    if (verb is! String) throw const FormatException('LX method');
    final method = verb.toUpperCase();
    if (!const {'GET', 'HEAD', 'POST'}.contains(method)) {
      throw const LxRequestException(LxRequestFailure.method);
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
    };
    final supplied = options['headers'];
    if (supplied != null && supplied is! Map) {
      throw const FormatException('LX headers');
    }
    for (final entry in (supplied as Map? ?? const {}).entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          name.length > 64 ||
          (value is! String && value is! num) ||
          headers.length >= 16 ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9a-zA-Z-]+$").hasMatch(name) ||
          const {
            'host',
            'connection',
            'content-length',
            'transfer-encoding',
            'trailer',
            'upgrade',
            'te',
            'cookie',
            'cookie2',
            'set-cookie',
            'authorization',
            'proxy-authorization',
            'accept-encoding',
            'forwarded',
            'x-forwarded-for',
            'x-forwarded-host',
            'x-real-ip',
          }.contains(name.toLowerCase()) ||
          name.toLowerCase().startsWith('proxy-') ||
          !RegExp(r'^[\x20-\x7e]{0,2048}$').hasMatch(value.toString())) {
        throw const LxRequestException(LxRequestFailure.headers);
      }
      final key = name.toLowerCase();
      headers[key] = const {'origin', 'referer'}.contains(key)
          ? _checkedWebHeader(value.toString(), origin: key == 'origin')
          : value.toString();
    }
    if (headers.entries.fold<int>(
          0,
          (sum, entry) => sum + entry.key.length + entry.value.length,
        ) >
        8192) {
      throw const LxRequestException(LxRequestFailure.headers);
    }
    Uint8List? body;
    final value = options['body'];
    final form = options['form'];
    final multipart = options['formData'];
    if (value != null || form != null || multipart != null) {
      if (method != 'POST' ||
          [value, form, multipart].where((part) => part != null).length > 1) {
        throw const FormatException('LX body');
      }
      if (form is Map) {
        final fields = <String>[];
        for (final entry in form.entries) {
          if (entry.key is! String ||
              (entry.value != null &&
                  entry.value is! String &&
                  entry.value is! num &&
                  entry.value is! bool)) {
            throw const FormatException('LX form');
          }
          fields.add(
            '${Uri.encodeComponent(entry.key as String)}='
            '${Uri.encodeComponent(entry.value?.toString() ?? 'null')}',
          );
        }
        headers['content-type'] = 'application/x-www-form-urlencoded';
        body = utf8.encode(fields.join('&'));
      } else if (form != null) {
        throw const FormatException('LX form');
      } else if (multipart is Map && multipart.length <= 64) {
        final random = Random.secure();
        final boundary =
            'motif-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
        final content = StringBuffer();
        for (final entry in multipart.entries) {
          final key = entry.key;
          final field = entry.value;
          if (key is! String ||
              key.length > 128 ||
              RegExp(r'[\x00-\x1f\x7f"\\]').hasMatch(key) ||
              (field != null &&
                  field is! String &&
                  field is! num &&
                  field is! bool)) {
            throw const LxRequestException(LxRequestFailure.body);
          }
          content.write(
            '--$boundary\r\nContent-Disposition: form-data; name="$key"\r\n\r\n${field?.toString() ?? 'null'}\r\n',
          );
          if (content.length > _apiBodyLimit) {
            throw const FormatException('LX body size');
          }
        }
        content.write('--$boundary--\r\n');
        headers['content-type'] = 'multipart/form-data; boundary=$boundary';
        body = utf8.encode(content.toString());
      } else if (multipart != null) {
        throw const LxRequestException(LxRequestFailure.body);
      } else if (value is Map &&
          value['type'] == 'Buffer' &&
          value['data'] is List) {
        final bytes = value['data'] as List;
        if (bytes.length > _apiBodyLimit ||
            bytes.any((byte) => byte is! int || byte < 0 || byte > 255)) {
          throw const LxRequestException(LxRequestFailure.body);
        }
        body = Uint8List.fromList(bytes.cast<int>());
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
    return LxApiRequest._(
      uri,
      method,
      headers,
      body,
      timeout,
      options['binary'] == true,
      options['_responseBytes'] == true,
      options['_followRedirects'] != false,
      onRedirect,
    );
  }
}

/// Runs one host-checked public HTTPS exchange with a total deadline.
final class LxHttpsTransport {
  const LxHttpsTransport({LxWireOpen? open}) : _open = open ?? openLxHttps;
  final LxWireOpen _open;

  Future<Map<String, Object?>> api(
    LxApiRequest request,
    PcmCancellation cancellation,
  ) async {
    final scope = PcmCancellation();
    final unlink = cancellation.listen(scope.cancel);
    final deadline = Timer(request.timeout, scope.cancel);
    LxWireResponse? reply;
    try {
      var uri = request.uri;
      var method = request.method;
      var headers = request.headers;
      var body = request.body;
      for (var redirects = 0; ; redirects++) {
        reply = await _open(uri, method, headers, body, scope);
        if (!request.followRedirects ||
            !const {301, 302, 303, 307, 308}.contains(reply.status)) {
          break;
        }
        final locations = reply.headers['location'];
        if (locations == null || locations.length != 1 || redirects >= 3) {
          throw const LxRequestException(LxRequestFailure.apiAddress);
        }
        final next = checkedLxUrl(uri.resolve(locations.single).toString());
        if (next == null) {
          throw const LxRequestException(LxRequestFailure.apiAddress);
        }
        final status = reply.status;
        reply.body.close();
        reply = null;
        request.onRedirect?.call();
        if ((status == 303 ||
                ((status == 301 || status == 302) && method == 'POST')) &&
            method != 'HEAD') {
          method = 'GET';
          body = null;
          headers = Map.of(headers)..remove('content-type');
        }
        if (uri.host != next.host && body != null) {
          throw const LxRequestException(LxRequestFailure.apiAddress);
        }
        if (uri.host != next.host) {
          // Script keys are scoped to the explicitly requested origin.
          headers = {
            for (final entry in headers.entries)
              if (const {
                'accept',
                'accept-language',
                'user-agent',
                'content-type',
              }.contains(entry.key))
                entry.key: entry.value,
          };
        }
        uri = next;
      }
      if (reply.status == 429) {
        throw const OnlineException(OnlineErrorKind.rateLimited);
      }
      final encodings = reply.headers['content-encoding'];
      if (encodings != null &&
          (encodings.length != 1 ||
              encodings.single.toLowerCase() != 'identity')) {
        throw const OnlineException(OnlineErrorKind.malformedResponse);
      }
      final bytes = await _readApiBody(reply, method);
      final raw = request.binary || request.responseBytes;
      if (raw && bytes.length > (request.binary ? 32 * 1024 : 16 * 1024)) {
        throw const OnlineException(OnlineErrorKind.malformedResponse);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
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
            if (!const {
              'set-cookie',
              'set-cookie2',
              'www-authenticate',
              'proxy-authenticate',
            }.contains(entry.key))
              entry.key: entry.value.join(', '),
        },
        'body': request.binary ? null : value,
        if (raw) '_rawBase64': base64Encode(bytes),
        if (request.binary) '_binary': true,
        if (request.responseBytes) '_desktop': true,
      };
    } on PcmCancelled {
      cancellation.check();
      throw const LxRequestException(LxRequestFailure.timeout);
    } on FixtureMediaException catch (error) {
      cancellation.check();
      if (error.kind == FixtureMediaFailure.denied) {
        throw const LxRequestException(LxRequestFailure.privateAddress);
      }
      throw const LxRequestException(LxRequestFailure.response);
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
    : _wholeFile = false,
      _open = open ?? _openMediaRange;

  /// Fresh downloads use a complete GET, not a playback seek/probe request.
  LxMediaTransport.download(this.uri, this.owner, {LxMediaOpen? open})
    : _wholeFile = true,
      _open = open ?? _openMediaRange;

  final Uri uri;
  final PcmCancellation owner;
  final bool _wholeFile;
  final LxMediaOpen _open;
  static const _downloadUserAgent =
      'Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/79.0.3945.79 Mobile Safari/537.36';
  Uri? _representation;

  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async {
    cancellation.check();
    if (_wholeFile && (offset != 0 || validator != null)) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    final scope = PcmCancellation();
    final unlistenOwner = owner.listen(scope.cancel);
    final unlisten = cancellation.listen(scope.cancel);
    var next = _representation ?? uri;
    try {
      for (var hop = 0; hop <= 3; hop++) {
        scope.check();
        next =
            checkedLxUrl(next.toString()) ??
            (throw const LxRequestException(LxRequestFailure.mediaAddress));
        final reply = await _open(next, {
          'accept':
              'audio/mpeg, audio/flac, audio/wav, application/octet-stream',
          if (_wholeFile) 'user-agent': _downloadUserAgent,
          if (!_wholeFile) ...{
            'range': 'bytes=$offset-',
            'if-range': ?validator,
          },
        }, scope);
        if (!const {301, 302, 303, 307, 308}.contains(reply.status)) {
          if (!_wholeFile &&
              offset == 0 &&
              const {200, 206}.contains(reply.status)) {
            _representation = next;
          }
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

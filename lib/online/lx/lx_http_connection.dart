import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../audio/controlled_pcm.dart';
import 'fixture/lx_fixture_wave.dart';

const lxWireTimeout = Duration(seconds: 3);
typedef LxWireResponse = ({
  int status,
  String reason,
  Map<String, List<String>> headers,
  LxSocketBody body,
});

/// Opens one checked hop. Keep the raw TCP socket until TLS setup finishes so
/// cancellation can also abandon a handshake that never responds.
Future<LxWireResponse> openLxHttps(
  Uri uri,
  String method,
  Map<String, String> headers,
  Uint8List? payload,
  PcmCancellation cancellation,
) async {
  final stopping = PcmCancellation();
  final unlisten = cancellation.listen(stopping.cancel);
  final budget = Timer(lxWireTimeout, stopping.cancel);
  LxSocketBody? body;
  try {
    stopping.check();
    final addresses = await stopping.until(InternetAddress.lookup(uri.host));
    if (addresses.isEmpty ||
        addresses.length > 32 ||
        addresses.any((address) => !isPublicLxAddress(address))) {
      throw const FixtureMediaException(FixtureMediaFailure.denied);
    }
    final approved = addresses.firstWhere(
      (ip) => ip.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
    stopping.check();
    final task = await stopping.until(
      RawSocket.startConnect(approved, 443),
      discard: (late) {
        unawaited(
          late.socket.then<void>(
            (socket) => unawaited(socket.close()),
            onError: (Object _) {},
          ),
        );
        late.cancel();
      },
    );
    final cancelDial = stopping.listen(task.cancel);
    RawSocket raw;
    try {
      raw = await stopping.until(
        task.socket,
        discard: (late) => unawaited(late.close()),
      );
    } finally {
      cancelDial();
    }
    final closeRaw = stopping.listen(() => unawaited(raw.close()));
    try {
      if (!_sameAddress(raw.remoteAddress, approved) || raw.remotePort != 443) {
        throw const FixtureMediaException(FixtureMediaFailure.denied);
      }
      final host = uri.host;
      final secure = await stopping.until(
        RawSecureSocket.secure(raw, host: host),
        discard: (late) => unawaited(late.close()),
      );
      if (stopping.cancelled) {
        unawaited(secure.close());
        stopping.check();
      }
      body = LxSocketBody(secure, stopping, unlisten);
      final path = uri.path.isEmpty ? '/' : uri.path;
      final target = uri.hasQuery ? '$path?${uri.query}' : path;
      final request = StringBuffer('$method $target HTTP/1.1\r\n')
        ..write('Host: $host\r\n')
        ..write('Accept-Encoding: identity\r\n')
        ..write('Connection: close\r\n');
      for (final entry in headers.entries) {
        request.write('${entry.key}: ${entry.value}\r\n');
      }
      if (method == 'POST') {
        request.write('Content-Length: ${payload?.length ?? 0}\r\n');
      }
      request.write('\r\n');
      await body.send(ascii.encode(request.toString()));
      if (payload != null) await body.send(payload);
      final metadata = await body._readHeaders(16 * 1024);
      stopping.check();
      return (
        status: metadata.status,
        reason: metadata.reason,
        headers: metadata.headers,
        body: body,
      );
    } catch (_) {
      unawaited(raw.close());
      rethrow;
    } finally {
      closeRaw();
    }
  } catch (error) {
    body?.close();
    unlisten();
    cancellation.check();
    if (error is FixtureMediaException) rethrow;
    throw const FixtureMediaException(FixtureMediaFailure.transport);
  } finally {
    budget.cancel();
  }
}

bool isPublicLxAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  if (bytes.length == 4 && address.type == InternetAddressType.IPv4) {
    final [a, b, c, _] = bytes;
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 &&
            (b == 168 ||
                (b == 0 && (c == 0 || c == 2)) ||
                (b == 88 && c == 99))) ||
        (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
        (a == 203 && b == 0 && c == 113));
  }
  if (bytes.length != 16 || address.type != InternetAddressType.IPv6) {
    return false;
  }
  return (bytes[0] & 0xe0) == 0x20 &&
      !(bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          (bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8))) &&
      !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
      !(bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] < 0x10) &&
      !address.address.contains('%');
}

bool _sameAddress(InternetAddress a, InternetAddress b) {
  final x = a.rawAddress;
  final y = b.rawAddress;
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

typedef _Headers = ({
  int status,
  String reason,
  Map<String, List<String>> headers,
});

// Read HTTP/1.1 headers and raw body bytes with backpressure.
final class LxSocketBody implements ControlledPcmRead {
  LxSocketBody(this._socket, this._scope, this._unlisten)
    : _events = StreamIterator(_socket) {
    _removeCancel = _scope.listen(close);
  }

  final RawSecureSocket _socket;
  final PcmCancellation _scope;
  final void Function() _unlisten;
  final StreamIterator<RawSocketEvent> _events;
  late final void Function() _removeCancel;
  Uint8List _remaining = Uint8List(0);
  bool _closed = false;
  bool _ended = false;

  Future<void> send(List<int> bytes) async {
    _socket.readEventsEnabled = false;
    var offset = 0;
    while (offset < bytes.length) {
      _scope.check();
      offset += _socket.write(bytes, offset);
      if (offset < bytes.length) {
        _socket.writeEventsEnabled = true;
        if (!await _next()) {
          throw const FixtureMediaException(FixtureMediaFailure.transport);
        }
      }
    }
    _socket.writeEventsEnabled = false;
    _socket.readEventsEnabled = true;
  }

  Future<_Headers> _readHeaders(int capacity) async {
    final bytes = <int>[];
    for (;;) {
      final part = await _receive(1024);
      if (part.isEmpty) {
        throw const FixtureMediaException(FixtureMediaFailure.transport);
      }
      for (var i = 0; i < part.length; i++) {
        if (bytes.length == capacity) {
          throw const FixtureMediaException(FixtureMediaFailure.transport);
        }
        bytes.add(part[i]);
        final end = bytes.length;
        if (end >= 4 &&
            bytes[end - 4] == 13 &&
            bytes[end - 3] == 10 &&
            bytes[end - 2] == 13 &&
            bytes[end - 1] == 10) {
          _remaining = Uint8List.sublistView(part, i + 1);
          return _parseHeaders(bytes.sublist(0, end - 4));
        }
      }
    }
  }

  @override
  Future<Uint8List> read(int maximum) async {
    _scope.check();
    if (_closed || maximum < 1 || maximum > 32 * 1024) {
      throw const FixtureMediaException(FixtureMediaFailure.transport);
    }
    if (_remaining.isNotEmpty) {
      final amount = maximum < _remaining.length ? maximum : _remaining.length;
      final bytes = Uint8List.sublistView(_remaining, 0, amount);
      _remaining = Uint8List.sublistView(_remaining, amount);
      return bytes;
    }
    final timer = Timer(lxWireTimeout, _scope.cancel);
    try {
      return await _receive(maximum);
    } on PcmCancelled {
      throw const FixtureMediaException(FixtureMediaFailure.transport);
    } on SocketException {
      throw const FixtureMediaException(FixtureMediaFailure.transport);
    } finally {
      timer.cancel();
    }
  }

  Future<Uint8List> _receive(int count) async {
    for (;;) {
      _scope.check();
      final bytes = _socket.read(count);
      if (bytes != null && bytes.isNotEmpty) return bytes;
      if (!await _next()) return Uint8List(0);
    }
  }

  Future<String> readLine(int limit) async {
    final line = <int>[];
    while (line.length < limit) {
      final next = await read(1);
      if (next.isEmpty) throw const FormatException('Truncated HTTP line');
      final code = next.single;
      if (code == 13) {
        final end = await read(1);
        if (end.length != 1 || end.single != 10) {
          throw const FormatException('Invalid HTTP line');
        }
        return ascii.decode(line);
      }
      if (code < 32 || code > 126) {
        throw const FormatException('Invalid HTTP line');
      }
      line.add(code);
    }
    throw const FormatException('Oversized HTTP line');
  }

  Future<bool> _next() async {
    if (_ended || _closed || !await _scope.until(_events.moveNext())) {
      return false;
    }
    _scope.check();
    final event = _events.current;
    _ended =
        event == RawSocketEvent.closed || event == RawSocketEvent.readClosed;
    return !_ended;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _removeCancel();
    _unlisten();
    _scope.cancel();
    unawaited(_events.cancel());
    unawaited(_socket.close());
    _remaining = Uint8List(0);
  }
}

_Headers _parseHeaders(List<int> bytes) {
  if (bytes.any(
    (byte) =>
        byte > 126 || (byte < 32 && byte != 13 && byte != 10 && byte != 9),
  )) {
    throw const FixtureMediaException(FixtureMediaFailure.transport);
  }
  final lines = ascii.decode(bytes).split('\r\n');
  final status = RegExp(r'^HTTP/1\.1 ([1-5]\d\d)(?: ([\x20-\x7e]*))?$')
      .firstMatch(lines.first);
  if (status == null || lines.length > 65) {
    throw const FixtureMediaException(FixtureMediaFailure.transport);
  }
  final headers = <String, List<String>>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon < 1 ||
        !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(line.substring(0, colon))) {
      throw const FixtureMediaException(FixtureMediaFailure.transport);
    }
    final value = line.substring(colon + 1).trim();
    if (value.length > 2048 || RegExp(r'[\r\n]').hasMatch(value)) {
      throw const FixtureMediaException(FixtureMediaFailure.transport);
    }
    (headers[line.substring(0, colon).toLowerCase()] ??= []).add(value);
  }
  return (
    status: int.parse(status[1]!),
    reason: status[2] ?? '',
    headers: headers,
  );
}

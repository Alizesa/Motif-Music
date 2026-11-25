import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'controlled_pcm.dart';

enum ControlledAudioFormat { mp3, flac }

/// A checked single-file representation. External URLs stay in its transport.
abstract interface class ControlledEncodedInput
    implements ControlledAudioInput {
  ControlledAudioFormat get format;
  int get size;
  bool get seekable;
  Future<ControlledPcmRead> openAt(int offset, PcmCancellation cancellation);
}

/// A private, read-only bridge for the decoder. It has no URL forwarding API.
final class ControlledAudioServer {
  ControlledAudioServer._(this.input, this._server, this._token) {
    _requests = _server.listen((request) => unawaited(_serve(request)));
  }

  final ControlledEncodedInput input;
  final HttpServer _server;
  final String _token;
  late final StreamSubscription<HttpRequest> _requests;
  final _closing = PcmCancellation();
  final _active = <PcmCancellation, ControlledPcmRead?>{};

  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_token/audio.${input.format.name}',
  );

  static Future<ControlledAudioServer> open(
    ControlledEncodedInput input,
    PcmCancellation cancellation,
  ) async {
    final server = await cancellation.until(
      HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false),
      discard: (late) => unawaited(late.close(force: true)),
    );
    server.autoCompress = false;
    server.idleTimeout = const Duration(seconds: 5);
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final result = ControlledAudioServer._(input, server, token);
    if (cancellation.cancelled) {
      result.close();
      cancellation.check();
    }
    return result;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    PcmCancellation? work;
    ControlledPcmRead? reader;
    void Function()? unlink;
    try {
      if (_closing.cancelled ||
          request.requestedUri.path != uri.path ||
          request.uri.hasQuery ||
          request.uri.hasFragment ||
          request.headers.value(HttpHeaders.hostHeader) !=
              '127.0.0.1:${_server.port}' ||
          request.connectionInfo?.remoteAddress.isLoopback != true ||
          request.contentLength > 0 ||
          !const {'GET', 'HEAD'}.contains(request.method)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      var start = 0;
      var end = input.size - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        start = int.tryParse(match[1]!) ?? -1;
        if (match[2]!.isNotEmpty) end = int.tryParse(match[2]!) ?? -1;
        if (start < 0 ||
            start >= input.size ||
            end < start ||
            (!input.seekable && start != 0)) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${input.size}',
          );
          return;
        }
        end = end.clamp(start, input.size - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${input.size}',
        );
      }
      response.headers
        ..contentType = ContentType(
          'audio',
          input.format == ControlledAudioFormat.mp3 ? 'mpeg' : 'flac',
        )
        ..set(HttpHeaders.acceptRangesHeader, input.seekable ? 'bytes' : 'none')
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');
      response.contentLength = end - start + 1;
      response.persistentConnection = false;
      if (request.method == 'HEAD') return;
      if (_active.length >= 2) {
        response.statusCode = HttpStatus.serviceUnavailable;
        response.contentLength = 0;
        return;
      }
      work = PcmCancellation();
      unlink = _closing.listen(work.cancel);
      _active[work] = null;
      unawaited(
        response.done.then<void>(
          (_) => work?.cancel(),
          onError: (Object _) => work?.cancel(),
        ),
      );
      final current = await work.until(
        input.openAt(start, work),
        discard: (late) => late.close(),
      );
      reader = current;
      _active[work] = current;
      var remaining = end - start + 1;
      while (remaining > 0) {
        work.check();
        final maximum = min(remaining, 32 * 1024);
        final bytes = await work.until(current.read(maximum));
        if (bytes.isEmpty || bytes.length > maximum) {
          throw const HttpException('Truncated audio');
        }
        response.add(bytes);
        await work.until(response.flush());
        remaining -= bytes.length;
      }
    } catch (_) {
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {
        // A decoder that cancelled the request already owns the connection.
      }
    } finally {
      reader?.close();
      unlink?.call();
      _active.remove(work);
      work?.cancel();
      try {
        await response.close();
      } catch (_) {
        /* Client disconnected. */
      }
    }
  }

  void close() {
    if (_closing.cancelled) return;
    _closing.cancel();
    for (final reader in _active.values) {
      reader?.close();
    }
    _active.clear();
    unawaited(_requests.cancel());
    unawaited(_server.close(force: true));
    input.close();
  }
}

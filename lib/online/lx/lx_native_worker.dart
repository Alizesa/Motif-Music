import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../audio/controlled_pcm.dart';
import '../domain/online_error.dart';
import 'lx_request_error.dart';
import 'lx_script_exchange.dart';
import 'fixture/lx_fixture_runtime.dart';

export 'lx_script_exchange.dart' show lxMessageLimit, lxScriptExchangeLimit;

const lxScriptLimit = 768 * 1024;
const lxWorkerTimeout = Duration(seconds: 34);
const _channel = MethodChannel('motif/lx_fixture');

typedef LxRequestHandler = LxExchangeHandler;

/// A single native run finishes only after its isolated process is reaped.
final class LxNativeWorker {
  const LxNativeWorker();

  bool get available => const LxFixtureRuntime().isAvailable;

  Future<Map<String, Object?>> run(
    Uint8List script, {
    required Map<String, String> info,
    Map<String, Object?>? event,
    required LxRequestHandler onRequest,
    required PcmCancellation cancellation,
  }) => LxFixtureRuntime.exclusive(() async {
    cancellation.check();
    if (!available || script.isEmpty || script.length > lxScriptLimit) {
      throw const OnlineException(OnlineErrorKind.unsupported);
    }
    final parameters = encodeLxMessage({
      'env': Platform.isAndroid ? 'mobile' : 'desktop',
      'info': info,
      'event': event,
    });
    final scope = PcmCancellation();
    final remove = cancellation.listen(scope.cancel);
    final deadline = Timer(lxWorkerTimeout, scope.cancel);
    final exchange = LxScriptExchange(scope, onRequest);

    try {
      final result = Platform.isAndroid
          ? await _android(script, parameters, exchange.reply, scope)
          : await _windows(script, parameters, exchange.reply, scope);
      scope.check();
      return decodeLxMessage(result);
    } catch (_) {
      cancellation.check();
      if (scope.cancelled) {
        throw const LxRequestException(LxRequestFailure.scriptTimeout);
      }
      throw const OnlineException(OnlineErrorKind.operationRejected);
    } finally {
      deadline.cancel();
      remove();
      scope.cancel();
      await exchange.close();
    }
  });

  static Future<Uint8List> _android(
    Uint8List script,
    Uint8List parameters,
    Future<Uint8List> Function(Uint8List) reply,
    PcmCancellation scope,
  ) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'scriptRequest' || call.arguments is! Uint8List) {
        throw PlatformException(code: 'lx-message');
      }
      return reply(call.arguments as Uint8List);
    });
    final remove = scope.listen(() {
      unawaited(
        _channel.invokeMethod<void>('cancel').catchError((Object _) {}),
      );
    });
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('runScript', {
        'script': script,
        'parameters': parameters,
      });
      return bytes ?? (throw const FormatException('LX result'));
    } finally {
      remove();
      _channel.setMethodCallHandler(null);
    }
  }

  static Future<Uint8List> _windows(
    Uint8List script,
    Uint8List parameters,
    Future<Uint8List> Function(Uint8List) reply,
    PcmCancellation scope,
  ) async {
    final app = File(Platform.resolvedExecutable).parent;
    final path = app.uri.resolve('motif_lx_probe.exe').toFilePath();
    final process = await Process.start(
      path,
      ['--app-script'],
      workingDirectory: app.path,
      runInShell: false,
    );
    final input = _FrameReader(process.stdout);
    final stderr = process.stderr.drain<void>();
    Future<void> closeInput() async {
      try {
        await process.stdin.close();
      } catch (_) {
        // The native controller may have already closed the pipe.
      }
    }

    Future<void> send(Uint8List bytes) async {
      final size = ByteData(4)..setUint32(0, bytes.length, Endian.little);
      process.stdin.add(size.buffer.asUint8List());
      process.stdin.add(bytes);
      await scope.until(process.stdin.flush());
    }

    final remove = scope.listen(() => unawaited(closeInput()));
    try {
      scope.check();
      await send(parameters);
      final length = ByteData(4)..setUint32(0, script.length, Endian.little);
      process.stdin.add(length.buffer.asUint8List());
      const partBytes = 32 * 1024;
      for (var start = 0; start < script.length; start += partBytes) {
        final end = (start + partBytes).clamp(start, script.length);
        await send(Uint8List.sublistView(script, start, end));
      }
      Uint8List? result;
      while (true) {
        final frame = await scope.until(input.next());
        if (frame == null) break;
        if (result != null || frame.length < 2) {
          throw const FormatException('LX frame');
        }
        final payload = Uint8List.sublistView(frame, 1);
        switch (frame.first) {
          case 81: // Q: exchange with the network broker
            await send(await reply(payload));
          case 68: // D: completion
            result = payload;
          default:
            throw const FormatException('LX frame type');
        }
      }
      if (await process.exitCode != 0 || result == null) {
        throw const FormatException('LX worker');
      }
      return result;
    } finally {
      remove();
      await closeInput();
      await input.close();
      await process.exitCode;
      await stderr;
    }
  }
}

final class _FrameReader {
  _FrameReader(Stream<List<int>> source) : _chunks = StreamIterator(source);

  final StreamIterator<List<int>> _chunks;
  List<int> _chunk = const [];
  int _offset = 0;

  Future<Uint8List?> next() async {
    final header = await _read(4, eof: true);
    if (header == null) return null;
    final size = ByteData.sublistView(header).getUint32(0, Endian.little);
    if (size < 2 || size > lxMessageLimit + 1) {
      throw const FormatException('LX frame size');
    }
    return _read(size);
  }

  Future<Uint8List?> _read(int size, {bool eof = false}) async {
    final out = Uint8List(size);
    var received = 0;
    while (received < size) {
      if (_offset == _chunk.length) {
        if (!await _chunks.moveNext()) {
          if (eof && received == 0) return null;
          throw const FormatException('Incomplete LX frame');
        }
        _chunk = _chunks.current;
        _offset = 0;
      }
      final count = (size - received).clamp(0, _chunk.length - _offset);
      out.setRange(received, received + count, _chunk, _offset);
      received += count;
      _offset += count;
    }
    return out;
  }

  Future<void> close() => _chunks.cancel();
}

Future<Uint8List?> pickAndroidLxScript() =>
    _channel.invokeMethod<Uint8List>('pickScript');

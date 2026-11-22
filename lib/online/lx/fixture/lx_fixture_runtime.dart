import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../audio/controlled_pcm.dart';
import 'lx_fixture_wave.dart';

const lxAppFixtureEnabled = bool.fromEnvironment('MOTIF_LX_APP_FIXTURE');

final class LxFixtureRuntimeException implements Exception {
  const LxFixtureRuntimeException(this.stage);
  final String stage;
}

/// Starts only the packaged, fixed script under the verified platform worker.
/// A successful result is an identity for the one fixture, not a playable URL.
final class LxFixtureRuntime {
  const LxFixtureRuntime();

  static const _channel = MethodChannel('motif/lx_fixture');
  static bool _running = false;

  bool get isAvailable =>
      lxAppFixtureEnabled && (Platform.isAndroid || Platform.isWindows);

  Future<String> resolve(PcmCancellation cancellation) async {
    if (!isAvailable) throw const LxFixtureRuntimeException('unavailable');
    if (_running) throw const LxFixtureRuntimeException('busy');
    _running = true;
    try {
      await _verify(cancellation, timeout: true, expected: 'MOTIF_LX_TIMEOUT');
      await _verify(
        cancellation,
        timeout: false,
        expected: 'MOTIF_LX_FIXED_WAVE',
      );
      return lxFixtureWaveUrl;
    } finally {
      _running = false;
    }
  }

  Future<void> _verify(
    PcmCancellation cancellation, {
    required bool timeout,
    required String expected,
  }) async {
    cancellation.check();
    String? marker;
    try {
      marker = Platform.isAndroid
          ? await _android(timeout, cancellation)
          : await _windows(timeout, cancellation);
    } catch (_) {
      cancellation.check();
      throw LxFixtureRuntimeException(timeout ? 'timeout' : 'runtime');
    }
    cancellation.check();
    if (marker != expected) {
      throw LxFixtureRuntimeException(timeout ? 'timeout' : 'runtime');
    }
  }

  Future<String?> _android(bool timeout, PcmCancellation cancellation) async {
    final pending = _channel.invokeMethod<String>('run', timeout);
    final unlisten = cancellation.listen(() {
      unawaited(
        _channel.invokeMethod<void>('cancel').catchError((Object _) {}),
      );
    });
    try {
      // The service controller completes this only after Binder death.
      return await pending;
    } finally {
      unlisten();
    }
  }

  Future<String?> _windows(bool timeout, PcmCancellation cancellation) async {
    final app = File(Platform.resolvedExecutable).parent;
    final scriptHost = app.uri.resolve('motif_lx_probe.exe');
    if (!await File.fromUri(scriptHost).exists()) {
      throw const LxFixtureRuntimeException('unavailable');
    }
    cancellation.check();
    final process = await Process.start(
      scriptHost.toFilePath(),
      [timeout ? '--app-fixture-timeout' : '--app-fixture'],
      workingDirectory: app.path,
      runInShell: false,
    );
    // Closing the control pipe tells the controller to terminate and reap
    // the restricted job. The controller exit acknowledges cleanup.
    final unlisten = cancellation.listen(() {
      unawaited(
        process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
      );
    });
    final errors = process.stderr.drain<void>();
    String? marker;
    var overflow = false;
    final output = <int>[];
    try {
      await for (final chunk in process.stdout) {
        if (output.length + chunk.length <= 4096 && !overflow) {
          output.addAll(chunk);
        } else {
          overflow = true;
          unawaited(
            process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
          );
        }
      }
      final status = await process.exitCode;
      await errors;
      if (status == 0 && !overflow) {
        for (final line in const LineSplitter().convert(ascii.decode(output))) {
          if (line == 'MOTIF_LX_FIXED_WAVE' || line == 'MOTIF_LX_TIMEOUT') {
            if (marker != null) return null;
            marker = line;
          }
        }
      }
      return marker;
    } finally {
      unlisten();
      await process.stdin.close().then<void>((_) {}, onError: (Object _) {});
    }
  }
}

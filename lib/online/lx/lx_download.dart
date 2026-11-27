import 'dart:typed_data';

import '../../audio/controlled_encoded.dart';
import '../../audio/controlled_pcm.dart';
import '../domain/download_source.dart';
import '../domain/online_error.dart';
import 'fixture/lx_fixture_wave.dart';
import 'lx_audio_media.dart';
import 'lx_audio_check.dart';

/// Runs the playback format/envelope checks over a tap of the original body.
/// Tags and artwork are saved unchanged; decoder-only transformations never
/// enter the destination. Validation and transfer use one media response.
Future<String> downloadLxAudio(
  FixtureRangeTransport transport,
  PcmCancellation cancellation,
  DownloadWrite write,
  void Function(int) onTotal, {
  LxAudioCheck? check,
}) async {
  final tap = _DownloadTransport(
    transport,
    cancellation,
    write,
    holdProbe: check != null,
  );
  ControlledAudioInput? checked;
  final release = cancellation.listen(() => tap.body?.close());
  try {
    checked = await openLxAudio(
      tap,
      cancellation,
      sequential: true,
      check: check,
    );
    final extension = checked is ControlledEncodedInput
        ? checked.format.name
        : 'wav';
    final total = tap.total;
    if (total <= 0 || total > 512 * 1024 * 1024) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    onTotal(total);
    final body = tap.body!;
    await body.flushProbe();
    while (body.count < total) {
      cancellation.check();
      final part = await cancellation.until(
        body.read((total - body.count).clamp(1, 32768)),
      );
      if (part.isEmpty) {
        throw const FixtureMediaException(FixtureMediaFailure.truncated);
      }
    }
    cancellation.check();
    if ((await cancellation.until(body.read(1))).isNotEmpty) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    return extension;
  } finally {
    checked?.close();
    final body = tap.body;
    body?.close();
    release();
    // Reads may be abandoned promptly, but aborting a temporary file must not
    // race the already-issued destination write (e.g. a RandomAccessFile).
    await body?.drainWrite();
  }
}

final class _DownloadTransport implements FixtureRangeTransport {
  _DownloadTransport(
    this.transport,
    this.cancellation,
    this.write, {
    required this.holdProbe,
  });
  final bool holdProbe;
  final FixtureRangeTransport transport;
  final PcmCancellation cancellation;
  final DownloadWrite write;
  _DownloadBody? body;
  int total = 0;

  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation request,
  ) async {
    if (body != null || offset != 0 || validator != null) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    // openLxAudio owns cancellation of the open; don't attach a second
    // cancellation race that could publish a body after the transfer exits.
    final response = await transport.open(0, null, request);
    if (cancellation.cancelled) {
      response.body.close();
      cancellation.check();
    }
    if (response.status != 200 && response.status != 206) {
      response.body.close();
      throw _DownloadHttpException(response.status);
    }
    // Keep the raw length to check EOF independently of the format probe.
    final lengths = response.headers['content-length'];
    total = lengths?.length == 1 ? int.tryParse(lengths!.single) ?? 0 : 0;
    final reader = body = _DownloadBody(
      response.body,
      write,
      cancellation,
      holdProbe: holdProbe,
    );
    return FixtureRangeResponse(
      status: response.status,
      headers: response.headers,
      body: reader,
    );
  }
}

/// Only display the status, never a reason phrase, response body, or URL.
final class _DownloadHttpException extends OnlineException {
  _DownloadHttpException(this.status)
    : super(switch (status) {
        404 || 410 => OnlineErrorKind.unavailable,
        429 => OnlineErrorKind.rateLimited,
        >= 500 => OnlineErrorKind.transport,
        _ => OnlineErrorKind.operationRejected,
      });

  final int status;

  @override
  String toString() => switch (status) {
    401 || 403 => '下载服务器拒绝了请求（HTTP $status）。可重试以获取新地址。',
    404 || 410 => '下载地址已失效或文件不存在（HTTP $status）。可重试以获取新地址。',
    429 => '下载服务器限制了请求频率（HTTP $status），请稍后重试。',
    >= 500 => '下载服务器暂时无法提供音频（HTTP $status），请稍后重试。',
    _ => '下载服务器未返回可保存的音频（HTTP $status）。',
  };
}

final class _DownloadBody implements ControlledPcmRead {
  _DownloadBody(
    this.inner,
    this.write,
    this.cancellation, {
    required bool holdProbe,
  }) : _prefix = holdProbe ? BytesBuilder(copy: true) : null;
  BytesBuilder? _prefix;

  Future<void> _save(Uint8List bytes) async {
    _writing = Future.microtask(() {
      cancellation.check();
      return write(bytes);
    });
    try {
      await _writing;
    } finally {
      _writing = null;
    }
  }

  Future<void> flushProbe() async {
    final bytes = _prefix?.takeBytes();
    _prefix = null;
    if (bytes == null) return;
    for (var pos = 0; pos < bytes.length; pos += 32768) {
      await _save(
        Uint8List.sublistView(bytes, pos, (pos + 32768).clamp(0, bytes.length)),
      );
    }
  }

  final ControlledPcmRead inner;
  final DownloadWrite write;
  final PcmCancellation cancellation;
  int count = 0;
  Future<void>? _writing;

  Future<void> drainWrite() async {
    try {
      await _writing;
    } catch (_) {
      // Cancellation already won the read. A late write error is not retried.
    }
  }

  @override
  Future<Uint8List> read(int maximum) async {
    cancellation.check();
    final bytes = await inner.read(maximum.clamp(1, 32768));
    cancellation.check();
    if (bytes.length > maximum || count + bytes.length > 512 * 1024 * 1024) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    if (bytes.isNotEmpty) {
      if (_prefix case final prefix?) {
        // ID3/FLAC metadata plus bounded frame lookahead. Never buffer a song.
        if (prefix.length + bytes.length > lxMaximumAudioMetadata + 32 * 1024) {
          throw const FixtureMediaException(FixtureMediaFailure.format);
        }
        prefix.add(bytes);
      } else {
        await _save(bytes);
      }
      count += bytes.length;
    }
    return bytes;
  }

  @override
  void close() {
    _prefix = null;
    inner.close();
  }
}

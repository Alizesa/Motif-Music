import 'dart:typed_data';

import '../../audio/controlled_encoded.dart';
import '../../audio/controlled_pcm.dart';
import '../domain/download_source.dart';
import 'fixture/lx_fixture_wave.dart';
import 'lx_audio_media.dart';

/// Runs the playback format/envelope checks over a tap of the original body.
/// Tags and artwork are saved unchanged; decoder-only transformations never
/// enter the destination. Validation and transfer use one media response.
Future<String> downloadLxAudio(
  FixtureRangeTransport transport,
  PcmCancellation cancellation,
  DownloadWrite write,
  void Function(int) onTotal,
) async {
  final tap = _DownloadTransport(transport, cancellation, write);
  ControlledAudioInput? checked;
  final release = cancellation.listen(() => tap.body?.close());
  try {
    checked = await openLxAudio(tap, cancellation);
    final extension = checked is ControlledEncodedInput
        ? checked.format.name
        : 'wav';
    final total = tap.total;
    if (total <= 0 || total > 512 * 1024 * 1024) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    onTotal(total);
    final body = tap.body!;
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
    tap.body?.close();
    release();
  }
}

final class _DownloadTransport implements FixtureRangeTransport {
  _DownloadTransport(this.transport, this.cancellation, this.write);
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
    final response = await cancellation.until(
      transport.open(0, null, request),
      discard: (late) => late.body.close(),
    );
    // openLxAudio validates status, full ranges, lengths and content encoding.
    // Keep the raw length here only to check the final EOF independently.
    final lengths = response.headers['content-length'];
    total = lengths?.length == 1 ? int.tryParse(lengths!.single) ?? 0 : 0;
    final reader = body = _DownloadBody(response.body, write, cancellation);
    return FixtureRangeResponse(
      status: response.status,
      headers: response.headers,
      body: reader,
    );
  }
}

final class _DownloadBody implements ControlledPcmRead {
  _DownloadBody(this.inner, this.write, this.cancellation);
  final ControlledPcmRead inner;
  final DownloadWrite write;
  final PcmCancellation cancellation;
  int count = 0;

  @override
  Future<Uint8List> read(int maximum) async {
    cancellation.check();
    final bytes = await inner.read(maximum.clamp(1, 32768));
    cancellation.check();
    if (bytes.length > maximum || count + bytes.length > 512 * 1024 * 1024) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    if (bytes.isNotEmpty) {
      await write(bytes);
      count += bytes.length;
    }
    return bytes;
  }

  @override
  void close() => inner.close();
}

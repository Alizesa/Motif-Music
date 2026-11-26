import 'dart:typed_data';

import '../../audio/controlled_pcm.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import '../qq/qq_track.dart';
import 'playback_source.dart';

typedef DownloadWrite = Future<void> Function(Uint8List bytes);

/// Only the host sees media addresses. Writes original bytes with backpressure;
/// returns the checked format extension after the complete response is read.
abstract interface class TrackDownloadSource {
  Set<OnlineQuality> get downloadQualities;

  Future<String> transfer(
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
    DiagnosticTrace? trace,
  });
}

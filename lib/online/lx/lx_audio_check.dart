import 'dart:math' as math;

import '../domain/online_error.dart';
import '../domain/playback_source.dart';

/// Checked against the original track, never a URL suffix, script tier claim,
/// or the duration of a different platform's search result.
final class LxAudioCheck {
  const LxAudioCheck(this.expectedMs, {this.downloadQuality});
  final int? expectedMs;
  final OnlineQuality? downloadQuality;

  void verify(
    String codec,
    double durationMs, {
    double? bitRate,
    int? depth,
    int? rate,
  }) {
    final expected = expectedMs;
    if (expected == null ||
        expected <= 0 ||
        !durationMs.isFinite ||
        durationMs <= 0) {
      throw const LxAudioCheckFailure('无法核实音频时长。');
    }
    if ((durationMs - expected).abs() > math.max(2000, expected * .02)) {
      throw const LxAudioCheckFailure('音频时长与原曲不符，可能是试听片段或其他版本。');
    }
    final highRes = (depth ?? 0) > 16 || (rate ?? 0) > 48000;
    final knownFlac = codec == 'flac' && (depth ?? 0) > 0 && (rate ?? 0) > 0;
    final matches = switch (downloadQuality) {
      null => true,
      OnlineQuality.standard =>
        codec == 'mp3' && bitRate != null && bitRate > 0 && bitRate <= 160000,
      OnlineQuality.high =>
        codec == 'mp3' &&
            bitRate != null &&
            bitRate > 160000 &&
            bitRate <= 384000,
      OnlineQuality.lossless => knownFlac && !highRes,
      OnlineQuality.hiRes => knownFlac && highRes,
    };
    if (!matches) {
      throw const LxAudioCheckFailure(
        '实际音频与所选下载音质不符。',
        kind: OnlineErrorKind.unsupportedQuality,
      );
    }
  }
}

final class LxAudioCheckFailure extends OnlineException {
  const LxAudioCheckFailure(
    this.message, {
    OnlineErrorKind kind = OnlineErrorKind.unavailable,
  }) : super(kind);
  const LxAudioCheckFailure.missingTrackDuration()
    : message = '缺少原曲时长，无法核实候选音频。',
      super(OnlineErrorKind.operationRejected);
  final String message;
  @override
  String toString() => message;
}

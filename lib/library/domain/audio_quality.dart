/// Quality data is deliberately nullable. A missing property is not evidence
/// that a file is low quality, so it must not be guessed from its extension or
/// file size.
class AudioQuality {
  const AudioQuality({
    this.bitrateKbps,
    this.sampleRateHz,
    this.channels,
    this.isLossless,
  }) : assert(bitrateKbps == null || bitrateKbps > 0),
       assert(sampleRateHz == null || sampleRateHz > 0),
       assert(channels == null || channels > 0);

  final int? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final bool? isLossless;

  bool get hasKnownMetric =>
      bitrateKbps != null ||
      sampleRateHz != null ||
      channels != null ||
      isLossless != null;

  /// Compares only explicitly reported properties.
  ///
  /// If one side is missing a property that the other side reports, the
  /// comparison is inconclusive. This prevents a partially parsed file from
  /// being silently treated as the highest-quality version.
  QualityComparison compareTo(AudioQuality other) {
    if (!hasKnownMetric || !other.hasKnownMetric) {
      return QualityComparison.incomparable;
    }

    var better = false;
    var worse = false;

    void compareInt(int? left, int? right) {
      if (left == null && right == null) return;
      if (left == null || right == null) {
        throw const _IncomparableQuality();
      }
      if (left > right) better = true;
      if (left < right) worse = true;
    }

    try {
      compareInt(bitrateKbps, other.bitrateKbps);
      compareInt(sampleRateHz, other.sampleRateHz);
      compareInt(channels, other.channels);
      if (isLossless != null || other.isLossless != null) {
        if (isLossless == null || other.isLossless == null) {
          throw const _IncomparableQuality();
        }
        if (isLossless! && !other.isLossless!) better = true;
        if (!isLossless! && other.isLossless!) worse = true;
      }
    } on _IncomparableQuality {
      return QualityComparison.incomparable;
    }

    if (better && worse) return QualityComparison.incomparable;
    if (better) return QualityComparison.better;
    if (worse) return QualityComparison.worse;
    return QualityComparison.equal;
  }

  String get displayLabel {
    final parts = <String>[
      if (isLossless == true) '无损',
      if (bitrateKbps case final bitrate?) '$bitrate kbps',
      if (sampleRateHz case final sampleRate?)
        '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz',
      if (channels case final channelCount?) '$channelCount 声道',
    ];
    return parts.isEmpty ? '音质信息未知' : parts.join(' · ');
  }
}

enum QualityComparison { better, equal, worse, incomparable }

class _IncomparableQuality implements Exception {
  const _IncomparableQuality();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/audio_quality.dart';
import 'package:motif/library/platform/taglib_metadata_reader.dart';

void main() {
  test('unknown and partially reported quality cannot establish highest', () {
    const known = AudioQuality(
      bitrateKbps: 320,
      sampleRateHz: 44100,
      channels: 2,
    );
    expect(
      known.compareTo(const AudioQuality()),
      QualityComparison.incomparable,
    );
    expect(
      known.compareTo(const AudioQuality(bitrateKbps: 128)),
      QualityComparison.incomparable,
    );
    expect(
      const AudioQuality().compareTo(const AudioQuality()),
      QualityComparison.incomparable,
    );
  });

  test('quality dominance requires metrics to agree in direction', () {
    const high = AudioQuality(
      bitrateKbps: 320,
      sampleRateHz: 48000,
      channels: 2,
    );
    const low = AudioQuality(
      bitrateKbps: 128,
      sampleRateHz: 44100,
      channels: 2,
    );
    const conflict = AudioQuality(
      bitrateKbps: 512,
      sampleRateHz: 32000,
      channels: 2,
    );
    expect(high.compareTo(low), QualityComparison.better);
    expect(low.compareTo(high), QualityComparison.worse);
    expect(high.compareTo(high), QualityComparison.equal);
    expect(high.compareTo(conflict), QualityComparison.incomparable);
    expect(
      const AudioQuality(isLossless: true)
          .compareTo(const AudioQuality(isLossless: false)),
      QualityComparison.better,
    );
    expect(
      high.compareTo(
        const AudioQuality(
          bitrateKbps: 320,
          sampleRateHz: 48000,
          channels: 2,
          isLossless: true,
        ),
      ),
      QualityComparison.incomparable,
    );
  });

  test('TagLib quality parsing preserves positive integers without guessing lossless', () {
    final tags = metadataFromTagLib({
      'title': 'Song',
      'durationMs': 180001,
      'bitrateKbps': 320,
      'sampleRateHz': 44100,
      'channels': 2,
      'isLossless': true,
    });
    expect(tags.durationMs, 180001);
    expect(tags.quality.displayLabel, '320 kbps · 44.1 kHz · 2 声道');
    expect(tags.isLossless, isNull);
  });

  for (final invalid in [null, 0, -1, 3.5, '320', true]) {
    test('TagLib ignores invalid numeric quality $invalid', () {
      final tags = metadataFromTagLib({
        'durationMs': invalid,
        'bitrateKbps': invalid,
        'sampleRateHz': invalid,
        'channels': invalid,
      });
      expect(tags.durationMs, isNull);
      expect(tags.quality.hasKnownMetric, isFalse);
    });
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';

import 'package:motif/audio/mpv_audio_engine.dart';

void main() {
  late RecordingPlayer player;
  late MpvAudioEngine engine;

  setUp(() {
    player = RecordingPlayer();
    engine = MpvAudioEngine(player: player);
  });

  test(
    'preamp uses native dB gain and preserves the accepted EQ chain',
    () async {
      await engine.setEqualizer([3, ...List<double>.filled(9, 0)]);
      await engine.setPreamp(-6);

      expect(player.gainWrites, [-6]);
      expect(player.effectsWrites, hasLength(1));
      expect(player.effectsWrites.single.whereType<RawAudioEffect>(), isEmpty);
    },
  );

  test('preamp accepts both limits and resets to unity at zero dB', () async {
    for (final gain in [-12.0, 12.0, 0.0]) {
      await engine.setPreamp(gain);
    }

    expect(player.gainWrites, [-12, 12, 0]);
    expect(player.effectsWrites, isEmpty);
  });

  test('invalid preamp values are rejected before any player write', () async {
    for (final gain in [
      -12.1,
      12.1,
      double.nan,
      double.negativeInfinity,
      double.infinity,
    ]) {
      await expectLater(engine.setPreamp(gain), throwsRangeError);
    }

    expect(player.gainWrites, isEmpty);
    expect(player.effectsWrites, isEmpty);
  });

  test('changing or flattening EQ preserves the independent preamp', () async {
    await engine.setPreamp(6);
    await engine.setEqualizer([3, ...List<double>.filled(9, 0)]);
    await engine.setEqualizer(List<double>.filled(10, 0));

    expect(player.gainWrites, [6]);
    expect(player.effectsWrites, hasLength(2));
    for (final effects in player.effectsWrites) {
      expect(effects, hasLength(10));
      expect(effects.every((effect) => effect is EqualizerEffect), isTrue);
      expect(
        effects.cast<EqualizerEffect>().map((effect) => effect.frequency),
        equalizerCentersHz,
      );
    }
    expect(
      player.effectsWrites.first.where((effect) => effect.enabled),
      hasLength(1),
    );
    expect(
      player.effectsWrites.last.where((effect) => effect.enabled),
      isEmpty,
    );
  });

  test('resetting preamp preserves total volume and EQ', () async {
    await engine.setVolume(40);
    await engine.setEqualizer([3, ...List<double>.filled(9, 0)]);
    await engine.setPreamp(6);
    await engine.setPreamp(0);

    expect(player.volumeWrites, [40]);
    expect(player.gainWrites, [6, 0]);
    expect(player.effectsWrites, hasLength(1));
  });

  test(
    'a refused gain write is reported and does not block a later write',
    () async {
      const error = MpvCommandException(
        name: 'options/volume-gain',
        code: -12,
        message: 'error running command',
      );
      player.gainError = error;
      await expectLater(engine.setPreamp(-6), throwsA(same(error)));
      player.gainError = null;
      await engine.setPreamp(0);

      expect(player.gainWrites, [-6, 0]);
      expect(player.effectsWrites, isEmpty);
    },
  );
}

final class RecordingPlayer implements PlayerApi {
  final gainWrites = <double>[];
  final volumeWrites = <double>[];
  final effectsWrites = <List<AudioEffect>>[];
  Object? gainError;

  @override
  Future<void> setVolumeGain(double gainDb) async {
    gainWrites.add(gainDb);
    if (gainError case final error?) throw error;
  }

  @override
  Future<void> setVolume(double volume) async => volumeWrites.add(volume);

  @override
  Future<void> setAudioEffects(List<AudioEffect> effects) async {
    effectsWrites.add(List<AudioEffect>.unmodifiable(effects));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

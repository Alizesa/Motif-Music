import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';
import 'package:motif/online/lx/lx_audio_check.dart';
import 'package:motif/online/lx/lx_audio_media.dart';

import '../support/lx_encoded_fixture.dart';
import '../support/lx_fixture_range.dart';

void main() {
  test('completeness tolerance: two seconds or two percent, including the boundary', () {
    for (final (expectMs, actual, pass) in [
      (30000, 32000, true),
      (30000, 32001, false),
      (200000, 196000, true),
      (200000, 195999, false),
      (279000, 306000, false),
      (0, 30000, false),
    ]) {
      void check() => LxAudioCheck(expectMs).verify('mp3', actual.toDouble());
      expect(
        check,
        pass ? returnsNormally : throwsA(isA<LxAudioCheckFailure>()),
      );
    }
  });
  test(
    'FLAC depth and rate distinguish ordinary lossless from Hi-Res, both ways',
    () async {
      for (final depth in [16, 24]) {
        for (final quality in [OnlineQuality.lossless, OnlineQuality.hiRes]) {
          final data = flacFixture();
          final meta = ByteData.sublistView(data);
          meta.setUint64(
            18,
            (44100 << 44) | (1 << 41) | ((depth - 1) << 36) | (44100 * 12),
          );
          final t = EncodedFixtureTransport(data);
          final result = openLxAudio(
            t,
            PcmCancellation(),
            check: LxAudioCheck(12000, downloadQuality: quality),
          );
          if ((depth == 16) == (quality == OnlineQuality.lossless)) {
            (await result).close();
          } else {
            await expectLater(result, throwsA(isA<LxAudioCheckFailure>()));
          }
          expect(t.readers.single.closed, isTrue);
        }
      }
    },
  );
  test('WAV frame duration is valid for playback, not a substitute for an MP3 download tier', () async {
    final bytes = WaveFixtureTransport().bytes;
    final expected = (bytes.length - 44) * 1000 ~/ 32000;
    (await openLxAudio(
      EncodedFixtureTransport(bytes),
      PcmCancellation(),
      sequential: true,
      check: LxAudioCheck(expected),
    )).close();
    await expectLater(
      openLxAudio(
        EncodedFixtureTransport(bytes),
        PcmCancellation(),
        sequential: true,
        check: LxAudioCheck(expected, downloadQuality: OnlineQuality.standard),
      ),
      throwsA(isA<LxAudioCheckFailure>()),
    );
  });
  for (final marker in ['Xing', 'Info', 'VBRI']) {
    test(
      '$marker frame count controls duration and impossible byte claims are rejected',
      () async {
        final data = mp3Fixture(id3: false);
        final fields = ByteData.sublistView(data);
        data.setAll(36, marker.codeUnits);
        if (marker == 'VBRI') {
          fields.setUint32(50, 460);
        } else {
          fields.setUint32(40, 3);
          fields.setUint32(44, 460);
        }
        final bytesAt = marker == 'VBRI' ? 46 : 48;
        fields.setUint32(bytesAt, data.length);
        (await openLxAudio(
          EncodedFixtureTransport(data),
          PcmCancellation(),
          check: const LxAudioCheck(12000),
        )).close();
        fields.setUint32(bytesAt, data.length + 100);
        await expectLater(
          openLxAudio(
            EncodedFixtureTransport(data),
            PcmCancellation(),
            check: const LxAudioCheck(12000),
          ),
          throwsA(isA<FixtureMediaException>()),
        );
      },
    );
  }
  test(
    'mixed MPEG bitrates without duration metadata cannot be certified as CBR',
    () async {
      final data = mp3Fixture(id3: false);
      final second = Uint8List(1044)..setAll(0, [255, 251, 224, 0]);
      final bytes = Uint8List.fromList([
        ...data.sublist(0, 417),
        ...second,
        ...data,
      ]);
      final transport = EncodedFixtureTransport(bytes);
      await expectLater(
        openLxAudio(
          transport,
          PcmCancellation(),
          check: const LxAudioCheck(12000),
        ),
        throwsA(isA<LxAudioCheckFailure>()),
      );
      expect(transport.readers.single.closed, isTrue);
    },
  );
}

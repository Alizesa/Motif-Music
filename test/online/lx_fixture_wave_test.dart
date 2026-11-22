import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';

import '../support/lx_fixture_range.dart';

Matcher failsWith(FixtureMediaFailure kind) => throwsA(
  isA<FixtureMediaException>().having((failure) => failure.kind, 'kind', kind),
);

void main() {
  test('only the fixed asset is authorized, before transport opens', () async {
    final transport = WaveFixtureTransport();
    await expectLater(
      FixtureWave.open(
        'https://other.invalid/audio.wav',
        transport,
        PcmCancellation(),
      ),
      failsWith(FixtureMediaFailure.denied),
    );
    expect(transport.opens, isEmpty);
  });

  test(
    'initial and Range readers only yield payload, with the same validator',
    () async {
      final transport = WaveFixtureTransport();
      final cancel = PcmCancellation();
      final wave = await FixtureWave.open(lxFixtureWaveUrl, transport, cancel);
      expect(
        (wave.channels, wave.sampleRate, wave.frames, wave.seekable),
        (1, 16000, 160000, true),
      );
      final start = await wave.openAt(0, cancel);
      expect(await start.read(16), transport.bytes.sublist(44, 60));
      expect(transport.opens, [(0, null)]);
      final distant = await wave.openAt(10000, cancel);
      expect(transport.opens.last, (20044, '"test"'));
      expect(await distant.read(16), transport.bytes.sublist(20044, 20060));
      wave.close();
      expect(transport.readers.every((reader) => reader.closed), isTrue);
    },
  );

  test('wrong seek representation closes the candidate and preserves the old reader', () async {
    final transport = WaveFixtureTransport();
    final cancel = PcmCancellation();
    final wave = await FixtureWave.open(lxFixtureWaveUrl, transport, cancel);
    final playing = await wave.openAt(0, cancel);
    for (final fault in ['200', '416', 'offset', 'etag', 'length']) {
      transport.fault = fault;
      await expectLater(
        wave.openAt(12000, cancel),
        failsWith(FixtureMediaFailure.range),
      );
      expect(transport.readers.last.closed, isTrue);
    }
    expect(await playing.read(16), transport.bytes.sublist(44, 60));
    wave.close();
  });

  test(
    'a mislabeled playlist or additional RIFF block yields no sample input',
    () async {
      for (final header in ['#EXTM3U', 'LIST']) {
        final transport = WaveFixtureTransport();
        final start = header == 'LIST' ? 36 : 0;
        transport.bytes.setRange(
          start,
          start + header.length,
          header.codeUnits,
        );
        await expectLater(
          FixtureWave.open(lxFixtureWaveUrl, transport, PcmCancellation()),
          failsWith(FixtureMediaFailure.format),
        );
        expect(transport.readers.single.closed, isTrue);
        expect(transport.opens, [(0, null)]);
      }
    },
  );

  test(
    'cancelling blocked initialization closes its response immediately',
    () async {
      final transport = WaveFixtureTransport()..blocked = true;
      final cancel = PcmCancellation();
      final result = expectLater(
        FixtureWave.open(lxFixtureWaveUrl, transport, cancel),
        throwsA(isA<PcmCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await result;
      expect(transport.readers.single.closed, isTrue);
    },
  );

  test(
    'a stale Range response is closed even when it arrives after cancellation',
    () async {
      final transport = WaveFixtureTransport();
      final wave = await FixtureWave.open(
        lxFixtureWaveUrl,
        transport,
        PcmCancellation(),
      );
      final late = transport.pending = Completer<void>();
      final cancel = PcmCancellation();
      final result = expectLater(
        wave.openAt(10000, cancel),
        throwsA(isA<PcmCancelled>()),
      );
      cancel.cancel();
      await result;
      late.complete();
      await Future<void>.delayed(Duration.zero);
      expect(transport.readers.last.closed, isTrue);
      wave.close();
    },
  );
}

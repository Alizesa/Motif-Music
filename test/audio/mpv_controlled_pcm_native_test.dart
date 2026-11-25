import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/audio_engine.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/audio/mpv_audio_engine.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';

import '../support/lx_fixture_range.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the app player consumes checked PCM, seeks through Range and releases it on replacement',
    () async {
      MpvAudioKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(
          autoPlay: false,
          resumePlayback: false,
        ),
      );
      final engine = MpvAudioEngine(player: player);
      final transport = WaveFixtureTransport();
      final wave = await FixtureWave.open(
        lxFixtureWaveUrl,
        transport,
        PcmCancellation(),
      );
      final outputErrors = <String>[];
      final errors = engine.errors.listen(outputErrors.add);
      final lengthKnown = engine.duration.firstWhere(
        (duration) => duration == const Duration(seconds: 10),
      );
      final local = await File(
        (await Directory.systemTemp.createTemp('motif-lx-fixture-')).uri
            .resolve('after-pcm.wav')
            .toFilePath(),
      ).writeAsBytes(transport.bytes);
      try {
        await player.setRawProperty('ao', 'null');
        const identity = 'motif-controlled:lx-test/1';
        final snapshots = <AudioQueueSnapshot>[];
        final queueEvents = engine.queue.listen(snapshots.add);
        addTearDown(queueEvents.cancel);
        final opening = engine.queue
            .firstWhere(
              (queue) => queue.currentTrack?.title == lxFixtureTrackTitle,
            )
            .timeout(const Duration(seconds: 5));
        await engine.openControlledPcm(
          wave,
          title: lxFixtureTrackTitle,
          identity: identity,
        );
        await lengthKnown.timeout(const Duration(seconds: 5));
        expect((await opening).currentTrack!.uri, identity);
        final initial = await player.stream.path
            .firstWhere((path) => path.startsWith('mak-pcm:'))
            .timeout(const Duration(seconds: 5));
        expect(initial, startsWith('mak-pcm:'));
        expect(initial, isNot(contains('https:')));
        expect(
          await engine.position
              .firstWhere(
                (position) => position > const Duration(milliseconds: 30),
              )
              .timeout(const Duration(seconds: 5)),
          greaterThan(Duration.zero),
        );
        expect(transport.opens, [(0, null)]);
        transport.fault = '200';
        await expectLater(
          engine.seek(const Duration(seconds: 4)),
          throwsA(isA<FixtureMediaException>()),
        );
        expect(player.state.file.path, initial);
        expect(transport.readers[1].closed, isTrue);
        transport.fault = null;
        final advanced = engine.position
            .firstWhere((position) => position >= const Duration(seconds: 7))
            .timeout(const Duration(seconds: 5));
        final newSegment = player.stream.path
            .firstWhere(
              (path) => path.startsWith('mak-pcm:') && path != initial,
            )
            .timeout(const Duration(seconds: 5));
        await engine.seek(const Duration(seconds: 7));
        await advanced;
        await newSegment;
        expect(transport.opens.last, (224044, '"test"'));
        expect(transport.readers.first.closed, isTrue);
        expect(player.state.file.path, isNot(initial));
        expect(player.state.file.path, startsWith('mak-pcm:'));
        final firstTrack = snapshots.indexWhere(
          (item) => item.currentTrack?.uri == identity,
        );
        expect(firstTrack, isNonNegative);
        expect(
          snapshots
              .skip(firstTrack)
              .every((item) => item.currentTrack?.uri == identity),
          isTrue,
        );
        expect(
          snapshots
              .where((item) => item.currentTrack?.title == lxFixtureTrackTitle)
              .map((item) => item.currentTrack!.uri)
              .toSet(),
          {identity},
        );

        final delayed = transport.pending = Completer<void>();
        final stale = expectLater(
          engine.seek(const Duration(seconds: 2)),
          throwsA(isA<PcmCancelled>()),
        );
        final switched = engine.queue.firstWhere(
          (queue) => queue.currentTrack?.title == 'Local fixture',
        );
        await engine.openQueue([
          AudioTrack(uri: local.uri.toString(), title: 'Local fixture'),
        ]);
        await stale;
        await switched.timeout(const Duration(seconds: 5));
        delayed.complete();
        await Future<void>.delayed(Duration.zero);
        expect(transport.opens.last, (64044, '"test"'));
        expect(transport.readers.every((reader) => reader.closed), isTrue);
        expect(outputErrors, isEmpty);
      } finally {
        await errors.cancel();
        await engine.dispose();
        await local.delete();
        await local.parent.delete();
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('MOTIF_LX_NATIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 25)),
  );
}

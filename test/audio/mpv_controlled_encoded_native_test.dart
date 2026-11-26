import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';
import 'package:motif/audio/controlled_encoded.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/audio/audio_engine.dart';
import 'package:motif/audio/mpv_audio_engine.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/online/lx/lx_audio_media.dart';

import '../support/lx_encoded_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'MP3 without reliable Range plays sequentially and does not claim seek support',
    () async {
      MpvAudioKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(
          autoPlay: false,
          resumePlayback: false,
        ),
      );
      final recorder = DiagnosticRecorder()..setEnabled(true);
      final engine = MpvAudioEngine(player: player, diagnostics: recorder);
      final transport = EncodedFixtureTransport(mp3Fixture())
        ..tag = null
        ..ranges = false;
      final input = await openLxAudio(
        transport,
        PcmCancellation(),
      ) as ControlledEncodedInput;
      final owner = PcmCancellation();
      final errors = <String>[];
      final subscription = engine.errors.listen(errors.add);
      try {
        await player.setRawProperty('ao', 'null');
        await engine.openControlledEncoded(
          input,
          title: 'Sequential MP3',
          identity: 'motif-controlled:sequential/1',
          cancellation: owner,
        );
        await engine.position
            .firstWhere((value) => value > const Duration(milliseconds: 30))
            .timeout(const Duration(seconds: 8));
        expect(input.seekable, isFalse);
        final log = utf8.decode(
          recorder.export({
            DiagnosticSection.player: engine.diagnosticSnapshot(),
          }).bytes,
        );
        final events = (jsonDecode(log) as Map)['events'] as List;
        expect(
          events.any(
            (event) =>
                event['event'] == 'nativePlaying' && event['playing'] == true,
          ),
          isTrue,
        );
        expect(log, isNot(contains('127.0.0.1')));
        expect(log, isNot(contains('Sequential MP3')));
        await expectLater(
          engine.seek(const Duration(seconds: 4)),
          throwsStateError,
        );
        owner.cancel();
        expect(errors, isEmpty);
      } finally {
        await subscription.cancel();
        await engine.dispose();
        recorder.dispose();
      }
      expect(transport.readers.every((reader) => reader.closed), isTrue);
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('MOTIF_LX_NATIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 25)),
  );
  for (final format in ControlledAudioFormat.values) {
    test(
      'the app decoder plays, seeks and revokes checked ${format.name} without the external URL',
      () async {
        MpvAudioKit.ensureInitialized();
        final player = Player(
          configuration: const PlayerConfiguration(
            autoPlay: false,
            resumePlayback: false,
          ),
        );
        final engine = MpvAudioEngine(player: player);
        final transport = EncodedFixtureTransport(
          format == ControlledAudioFormat.mp3 ? mp3Fixture() : flacFixture(),
        );
        final input = await openLxAudio(
          transport,
          PcmCancellation(),
        ) as ControlledEncodedInput;
        final owner = PcmCancellation();
        final errors = <String>[];
        final subscription = engine.errors.listen(errors.add);
        const identity = 'motif-controlled:encoded-test/1';
        try {
          await player.setRawProperty('ao', 'null');
          final duration = engine.duration.firstWhere(
            (duration) => duration > const Duration(seconds: 10),
          );
          final decoded = player.stream.path.firstWhere(
            (path) => path.startsWith('http://127.0.0.1:'),
          );
          await engine.openControlledEncoded(
            input,
            title: 'Checked ${format.name}',
            identity: identity,
            cancellation: owner,
          );
          await decoded.timeout(const Duration(seconds: 8));
          await duration.timeout(const Duration(seconds: 8));
          expect(
            await player.getRawProperty('audio-codec-name'),
            startsWith(format.name),
          );
          expect(
            await player.getRawProperty('options/demuxer-lavf-format'),
            format.name,
          );
          expect(
            await player.getRawProperty('options/access-references'),
            'no',
          );
          expect(
            await player.getRawProperty('options/demuxer-lavf-o'),
            contains('protocol_whitelist=none'),
          );
          final queue = await engine.queue
              .firstWhere((queue) => queue.currentTrack?.uri == identity)
              .timeout(const Duration(seconds: 5));
          expect(queue.currentTrack?.title, 'Checked ${format.name}');
          await engine.position
              .firstWhere(
                (position) => position > const Duration(milliseconds: 30),
              )
              .timeout(const Duration(seconds: 5));
          final sought = engine.position.firstWhere(
            (position) => position >= const Duration(seconds: 6),
          );
          await engine.seek(const Duration(seconds: 7));
          await sought.timeout(const Duration(seconds: 5));
          final stopped = player.stream.path.firstWhere((path) => path.isEmpty);
          owner.cancel();
          await stopped.timeout(const Duration(seconds: 5));
          expect(transport.readers.every((reader) => reader.closed), isTrue);
          final local = await File(
            '${(await Directory.systemTemp.createTemp('motif-decoder-reset-')).path}/reset.mp3',
          ).writeAsBytes(mp3Fixture(id3: false));
          try {
            final path = player.stream.path.firstWhere(
              (path) => !path.startsWith('http:') && path.endsWith('reset.mp3'),
            );
            await engine.openQueue([
              AudioTrack(
                uri: local.uri.toString(),
                title: 'Local after ${format.name}',
              ),
            ]);
            await path.timeout(const Duration(seconds: 5));
            await player.stream.audioParams
                .firstWhere(
                  (value) => value.codecName?.startsWith('mp3') == true,
                )
                .timeout(const Duration(seconds: 5));
            expect(
              await player.getRawProperty('audio-codec-name'),
              startsWith('mp3'),
            );
            expect(
              await player.getRawProperty('options/demuxer-lavf-format'),
              '',
            );
          } finally {
            await player.stop();
            await local.delete();
            await local.parent.delete();
          }
          expect(errors, isEmpty);
        } finally {
          await subscription.cancel();
          await engine.dispose();
        }
      },
      skip:
          !Platform.isWindows ||
          !const bool.fromEnvironment('MOTIF_LX_NATIVE_TEST'),
      timeout: const Timeout(Duration(seconds: 35)),
    );
  }
}

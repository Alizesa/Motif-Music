import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_encoded.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/lx_audio_media.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';
import 'package:motif/online/domain/online_error.dart';

import '../support/lx_encoded_fixture.dart';
import '../support/lx_fixture_range.dart';

void main() {
  test('media HTTP failures retain their own cause rather than claiming an unsupported codec', () async {
    for (final item in [
      (429, OnlineErrorKind.rateLimited),
      (403, OnlineErrorKind.operationRejected),
    ]) {
      final transport = EncodedFixtureTransport(mp3Fixture())
        ..fault = '${item.$1}';
      await expectLater(
        openLxAudio(transport, PcmCancellation()),
        throwsA(
          isA<OnlineException>().having((error) => error.kind, 'kind', item.$2),
        ),
      );
      expect(transport.readers.single.closed, isTrue);
    }
  });
  test('detects MP3 frames, strips ID3, streams and maps byte seeks to the same resource', () async {
    final transport = EncodedFixtureTransport(mp3Fixture());
    final input = await openLxAudio(
      transport,
      PcmCancellation(),
    ) as ControlledEncodedInput;
    expect(input.format, ControlledAudioFormat.mp3);
    expect(input.seekable, isTrue);
    expect(input.size, transport.bytes.length - 74);
    final first = await input.openAt(0, PcmCancellation());
    expect((await first.read(4)).take(2), [255, 251]);
    first.close();
    final next = await input.openAt(4170, PcmCancellation());
    expect(transport.opens.last, (4244, '"same-file"'));
    expect(await next.read(4), transport.bytes.sublist(4244, 4248));
    input.close();
    expect(transport.readers.every((reader) => reader.closed), isTrue);
  });

  test('FLAC preserves STREAMINFO and frames while removing optional reference metadata', () async {
    final original = flacFixture();
    final transport = EncodedFixtureTransport(original);
    final input = await openLxAudio(
      transport,
      PcmCancellation(),
    ) as ControlledEncodedInput;
    expect(input.format, ControlledAudioFormat.flac);
    expect(input.size, original.length - 16);
    final first = await input.openAt(0, PcmCancellation());
    final prefix = await first.read(42);
    expect(ascii.decode(prefix.take(4).toList()), 'fLaC');
    expect(prefix[4], 128);
    first.close();
    final next = await input.openAt(42, PcmCancellation());
    expect(transport.opens.last, (58, '"same-file"'));
    expect(await next.read(2), [255, 248]);
    input.close();
  });

  test(
    'PCM WAV still uses the checked PCM path without a second initial request',
    () async {
      final transport = WaveFixtureTransport();
      final input = await openLxAudio(transport, PcmCancellation());
      expect(input, isA<ControlledPcmInput>());
      expect(transport.opens, [(0, null)]);
      input.close();
    },
  );

  test('rejects HTML, playlists, fake suffixes, malformed frames and excessive metadata', () async {
    final excessive = Uint8List.fromList([
      73,
      68,
      51,
      4,
      0,
      0,
      127,
      127,
      127,
      127,
      ...List.filled(50, 0),
    ]);
    for (final bytes in [
      utf8.encode('#EXTM3U\nhttps://unexpected.example/song.mp3'),
      utf8.encode('<html>not an mp3 or flac</html>'),
      excessive,
      Uint8List.fromList([255, 251, 240, 0, ...List.filled(500, 0)]),
      Uint8List.fromList([
        102,
        76,
        97,
        67,
        128,
        0,
        0,
        34,
        ...List.filled(500, 0),
      ]),
    ]) {
      final transport = EncodedFixtureTransport(Uint8List.fromList(bytes));
      await expectLater(
        openLxAudio(transport, PcmCancellation()),
        throwsA(isA<FixtureMediaException>()),
      );
      expect(transport.readers.single.closed, isTrue);
    }
  });

  test('a changed validator, wrong Range or full response cannot replace a checked stream', () async {
    for (final fault in ['etag', 'offset', '200']) {
      final transport = EncodedFixtureTransport(mp3Fixture());
      final input = await openLxAudio(
        transport,
        PcmCancellation(),
      ) as ControlledEncodedInput;
      transport.fault = fault;
      await expectLater(
        input.openAt(10000, PcmCancellation()),
        throwsA(isA<FixtureMediaException>()),
      );
      expect(transport.readers.last.closed, isTrue);
      input.close();
    }
  });

  test('media with no validator can play sequentially without claiming seek support', () async {
    final transport = EncodedFixtureTransport(mp3Fixture())
      ..tag = null
      ..ranges = false;
    final input = await openLxAudio(
      transport,
      PcmCancellation(),
    ) as ControlledEncodedInput;
    expect(input.seekable, isFalse);
    final reader = await input.openAt(0, PcmCancellation());
    expect(await reader.read(2), [255, 251]);
    await expectLater(
      input.openAt(2000, PcmCancellation()),
      throwsA(isA<FixtureMediaException>()),
    );
    input.close();
  });

  test('a late seek response is closed after source cancellation', () async {
    final transport = EncodedFixtureTransport(mp3Fixture());
    final input = await openLxAudio(
      transport,
      PcmCancellation(),
    ) as ControlledEncodedInput;
    final gate = transport.pending = Completer<void>();
    final pending = input.openAt(2000, PcmCancellation());
    final expectation = expectLater(pending, throwsA(isA<PcmCancelled>()));
    input.close();
    await expectation;
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(transport.readers.every((reader) => reader.closed), isTrue);
  });

  test('decoder endpoint only serves its private single-file path and bounded ranges', () async {
    final transport = EncodedFixtureTransport(mp3Fixture());
    final input = await openLxAudio(
      transport,
      PcmCancellation(),
    ) as ControlledEncodedInput;
    final server = await ControlledAudioServer.open(input, PcmCancellation());
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final blocked = await (await client.getUrl(
        server.uri.replace(path: '/other'),
      )).close();
      expect(blocked.statusCode, 403);
      await blocked.drain<void>();
      expect(transport.opens, hasLength(1));
      final range = await client.getUrl(server.uri);
      range.headers.set('range', 'bytes=4170-4173');
      final reply = await range.close();
      expect(reply.statusCode, 206);
      expect(
        await reply.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
        [255, 251, 144, 0],
      );
      final invalid = await client.getUrl(server.uri);
      invalid.headers.set('range', 'bytes=0-1,4-5');
      final refused = await invalid.close();
      expect(refused.statusCode, 416);
      await refused.drain<void>();
    } finally {
      client.close(force: true);
      server.close();
    }
    expect(transport.readers.every((reader) => reader.closed), isTrue);
  });
}

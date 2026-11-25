import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';
import 'package:motif/online/lx/lx_download.dart';

import '../support/lx_encoded_fixture.dart';
import '../support/lx_fixture_range.dart';

void main() {
  for (final entry in [
    ('mp3', mp3Fixture()),
    ('flac', flacFixture()),
    ('wav', WaveFixtureTransport().bytes),
  ]) {
    test(
      'downloads ${entry.$1} byte for byte, preserving tags, with one response',
      () async {
        final transport = EncodedFixtureTransport(entry.$2);
        final saved = BytesBuilder();
        int? total;
        final extension = await downloadLxAudio(transport, PcmCancellation(), (
          chunk,
        ) async {
          expect(chunk.length, lessThanOrEqualTo(32768));
          saved.add(chunk);
        }, (value) => total = value);
        expect(extension, entry.$1);
        expect(saved.takeBytes(), entry.$2);
        expect(total, entry.$2.length);
        expect(transport.opens, [(0, null)]);
        expect(transport.readers.every((reader) => reader.closed), isTrue);
      },
    );
  }

  test('accepts a sequential media response without Range or ETag', () async {
    final transport = EncodedFixtureTransport(mp3Fixture())
      ..ranges = false
      ..tag = null;
    final saved = BytesBuilder();
    await downloadLxAudio(
      transport,
      PcmCancellation(),
      (bytes) async => saved.add(bytes),
      (_) {},
    );
    expect(saved.takeBytes(), transport.bytes);
    expect(transport.opens.length, 1);
  });

  test(
    'rejects truncated and oversized bodies instead of claiming completion',
    () async {
      final bytes = mp3Fixture();
      for (final difference in [-5, 5]) {
        final transport = _Transport(bytes, bytes.length + difference);
        await expectLater(
          downloadLxAudio(transport, PcmCancellation(), (_) async {}, (_) {}),
          throwsA(isA<FixtureMediaException>()),
        );
        expect(transport.reader.closed, isTrue);
      }
    },
  );

  test('cancellation closes a body stalled after format validation', () async {
    final transport = _Transport(
      mp3Fixture(),
      mp3Fixture().length,
      block: true,
    );
    final cancellation = PcmCancellation();
    final validated = Completer<void>();
    final transfer = downloadLxAudio(
      transport,
      cancellation,
      (_) async {},
      (_) => validated.complete(),
    );
    final result = expectLater(transfer, throwsA(isA<PcmCancelled>()));
    await validated.future;
    cancellation.cancel();
    await result;
    expect(transport.reader.closed, isTrue);
  });

  test('a disk write failure stops reads and releases the body', () async {
    final transport = EncodedFixtureTransport(mp3Fixture());
    await expectLater(
      downloadLxAudio(transport, PcmCancellation(), (_) async {
        throw StateError('disk full');
      }, (_) {}),
      throwsStateError,
    );
    expect(transport.readers.single.closed, isTrue);
  });

  test('rejects non-audio content before reporting a saved format', () async {
    final transport = EncodedFixtureTransport(
      Uint8List.fromList(List.filled(1000, 60)),
    );
    await expectLater(
      downloadLxAudio(transport, PcmCancellation(), (_) async {}, (_) {}),
      throwsA(isA<FixtureMediaException>()),
    );
    expect(transport.readers.single.closed, isTrue);
  });
}

class _Transport implements FixtureRangeTransport {
  _Transport(Uint8List bytes, this.length, {bool block = false})
    : reader = _Body(bytes, block);
  final int length;
  final _Body reader;
  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async => FixtureRangeResponse(
    status: 200,
    headers: {
      'content-length': ['$length'],
      'content-type': ['audio/mpeg'],
    },
    body: reader,
  );
}

class _Body implements ControlledPcmRead {
  _Body(this.bytes, this.block);
  final Uint8List bytes;
  final bool block;
  int offset = 0;
  bool closed = false;
  final waiting = Completer<Uint8List>();
  @override
  Future<Uint8List> read(int maximum) async {
    if (block && offset > 500) return waiting.future;
    final count = maximum.clamp(0, bytes.length - offset);
    final result = bytes.sublist(offset, offset + count);
    offset += count;
    return result;
  }

  @override
  void close() {
    closed = true;
    if (!waiting.isCompleted) waiting.complete(Uint8List(0));
  }
}

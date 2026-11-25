import 'dart:async';
import 'dart:typed_data';

import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';

// Self-generated silent MPEG-1 Layer III frames, with no third-party recording.
Uint8List mp3Fixture({bool id3 = true}) {
  final result = BytesBuilder();
  if (id3) {
    result.add([73, 68, 51, 4, 0, 0, 0, 0, 0, 64, ...List.filled(64, 0)]);
  }
  for (var frame = 0; frame < 460; frame++) {
    result.add([255, 251, 144, 0, ...List.filled(413, 0)]);
  }
  return result.takeBytes();
}

// Native FLAC constant subframes, stereo 16-bit silence at 44.1 kHz.
Uint8List flacFixture({bool metadata = true}) {
  const samples = 44100 * 12;
  final info = Uint8List(34);
  final data = ByteData.sublistView(info);
  data.setUint16(0, samples % 4096);
  data.setUint16(2, 4096);
  data.setUint64(10, (44100 << 44) | (1 << 41) | (15 << 36) | samples);
  final bytes = BytesBuilder()
    ..add([102, 76, 97, 67, metadata ? 0 : 128, 0, 0, 34, ...info]);
  if (metadata) {
    // An application metadata block is ignored by the single-file bridge.
    bytes.add([130, 0, 0, 12, ...List.filled(12, 0)]);
  }
  var left = samples;
  for (var frame = 0; left > 0; frame++) {
    final block = left.clamp(0, 4096);
    final header = <int>[
      255,
      248,
      block == 4096 ? 201 : 121,
      24,
      if (frame < 128) frame else ...[192 | (frame >> 6), 128 | (frame & 63)],
      if (block != 4096) ...[(block - 1) >> 8, (block - 1) & 255],
    ];
    header.add(_crc(header, 8, 7));
    final encoded = <int>[...header, 0, 0, 0, 0, 0, 0];
    final crc = _crc(encoded, 16, 0x8005);
    bytes.add([...encoded, crc >> 8, crc & 255]);
    left -= block;
  }
  return bytes.takeBytes();
}

int _crc(List<int> bytes, int width, int polynomial) {
  var value = 0;
  for (final byte in bytes) {
    value ^= byte << (width - 8);
    for (var bit = 0; bit < 8; bit++) {
      value =
          ((value << 1) ^
              ((value & (1 << (width - 1))) != 0 ? polynomial : 0)) &
          ((1 << width) - 1);
    }
  }
  return value;
}

final class EncodedFixtureTransport implements FixtureRangeTransport {
  EncodedFixtureTransport(this.bytes);
  final Uint8List bytes;
  final opens = <(int, String?)>[];
  final readers = <EncodedFixtureRead>[];
  String? tag = '"same-file"';
  bool ranges = true;
  String? fault;
  Completer<void>? pending;

  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async {
    opens.add((offset, validator));
    if (pending case final wait?) await wait.future;
    final reader = EncodedFixtureRead(bytes, offset);
    readers.add(reader);
    final length = bytes.length - offset;
    return FixtureRangeResponse(
      status: int.tryParse(fault ?? '') ?? (!ranges ? 200 : 206),
      headers: {
        'content-type': ['application/octet-stream'],
        'content-length': ['$length'],
        if (ranges && fault != '200')
          'content-range': [
            'bytes ${fault == 'offset' ? offset + 1 : offset}-${bytes.length - 1}/${bytes.length}',
          ],
        if (tag != null) 'etag': [fault == 'etag' ? '"new-file"' : tag!],
      },
      body: reader,
    );
  }
}

final class EncodedFixtureRead implements ControlledPcmRead {
  EncodedFixtureRead(this.bytes, this.offset);
  final Uint8List bytes;
  int offset;
  bool closed = false;
  @override
  Future<Uint8List> read(int maximum) async {
    if (closed) throw const PcmCancelled();
    final end = (offset + maximum).clamp(offset, bytes.length);
    final next = Uint8List.sublistView(bytes, offset, end);
    offset = end;
    return next;
  }

  @override
  void close() => closed = true;
}

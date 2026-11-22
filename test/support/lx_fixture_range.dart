import 'dart:async';
import 'dart:typed_data';

import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';

final class WaveFixtureTransport implements FixtureRangeTransport {
  final Uint8List bytes = _waveBytes();
  final opens = <(int, String?)>[];
  final readers = <FixtureBody>[];
  bool blocked = false;
  String? fault;
  Completer<void>? pending;

  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async {
    opens.add((offset, validator));
    if (pending case final delay?) await delay.future;
    final reader = FixtureBody(bytes, offset, blocked: blocked);
    readers.add(reader);
    final total = bytes.length;
    final start = fault == 'offset' ? offset - 2 : offset;
    final end = total - 1;
    final length = total - offset - (fault == 'length' ? 2 : 0);
    return FixtureRangeResponse(
      status: int.tryParse(fault ?? '') ?? 206,
      headers: {
        'content-range': ['bytes $start-$end/$total'],
        'content-length': ['$length'],
        'content-type': ['audio/wav'],
        'etag': [fault == 'etag' ? '"replacement"' : '"test"'],
      },
      body: reader,
    );
  }
}

final class FixtureBody implements ControlledPcmRead {
  FixtureBody(this.bytes, this.offset, {required this.blocked});
  final Uint8List bytes;
  final bool blocked;
  final _close = Completer<Uint8List>();
  int offset;
  bool get closed => _close.isCompleted;

  @override
  Future<Uint8List> read(int maximum) async {
    if (blocked) return _close.future;
    final count = maximum.clamp(0, bytes.length - offset);
    final result = bytes.sublist(offset, offset + count);
    offset += count;
    return result;
  }

  @override
  void close() {
    if (!closed) _close.complete(Uint8List(0));
  }
}

Uint8List _waveBytes() {
  final bytes = Uint8List.fromList(
    List.generate(320044, (index) => index % 251),
  );
  final data = ByteData.sublistView(bytes);
  void fourCc(int start, String value) =>
      bytes.setRange(start, start + 4, value.codeUnits);
  fourCc(0, 'RIFF');
  data.setUint32(4, 320036, Endian.little);
  fourCc(8, 'WAVE');
  fourCc(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  fourCc(36, 'data');
  data.setUint32(40, 320000, Endian.little);
  return bytes;
}

import 'dart:convert';
import 'dart:typed_data';

List<int> wavFixture({bool tagged = false, int seconds = 1}) {
  List<int> u32(int n) =>
      (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
  List<int> chunk(String name, List<int> value) => [
    ...ascii.encode(name),
    ...u32(value.length),
    ...value,
    if (value.length.isOdd) 0,
  ];
  final pcm = Uint8List(16000 * seconds); // 8 kHz mono signed 16-bit PCM.
  final format =
      (ByteData(16)
            ..setUint16(0, 1, Endian.little)
            ..setUint16(2, 1, Endian.little)
            ..setUint32(4, 8000, Endian.little)
            ..setUint32(8, 16000, Endian.little)
            ..setUint16(12, 2, Endian.little)
            ..setUint16(14, 16, Endian.little))
          .buffer
          .asUint8List();
  final body = [
    ...ascii.encode('WAVE'),
    ...chunk('fmt ', format),
    if (tagged)
      ...chunk('LIST', [
        ...ascii.encode('INFO'),
        ...chunk('INAM', [...ascii.encode('A "song"'), 0]),
        ...chunk('IART', [...ascii.encode('Artist'), 0]),
        ...chunk('IPRD', [...ascii.encode('Album'), 0]),
      ]),
    ...chunk('data', pcm),
  ];
  return [...ascii.encode('RIFF'), ...u32(body.length), ...body];
}

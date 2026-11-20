@Tags(['taglib-native'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'package:motif_taglib/motif_taglib.dart';

List<int> wavFixture({bool tagged = false}) {
  List<int> u32(int n) =>
      (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
  List<int> chunk(String name, List<int> value) => [
    ...ascii.encode(name),
    ...u32(value.length),
    ...value,
    if (value.length.isOdd) 0,
  ];
  final pcm = Uint8List(16000); // 8,000 mono signed-16 samples = one second.
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

void main() {
  for (final tagged in [false, true]) {
    test(
      'native readonly WAV extraction (tagged=$tagged) handles Unicode paths and releases handles',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'motif-taglib-',
        );
        try {
          final file = File(
            '${directory.path}${Platform.pathSeparator}中文 音乐.wav',
          );
          final bytes = wavFixture(tagged: tagged);
          await file.writeAsBytes(bytes);
          for (var i = 0; i < 3; i++) {
            final path = file.path;
            final tags = await Isolate.run(() => readTagLib(path: path));
            expect(tags['title'], tagged ? 'A "song"' : '');
            expect(tags['artist'], tagged ? 'Artist' : '');
            expect(tags['album'], tagged ? 'Album' : '');
            expect(tags['durationMs'], 1000);
          }
          expect(await file.readAsBytes(), bytes);
          await file.rename('${file.path}.renamed');
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test('native invalid file fails without retaining its read handle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'motif-taglib-invalid-',
    );
    try {
      final file = File('${directory.path}${Platform.pathSeparator}bad.flac');
      await file.writeAsString('not audio');
      final path = file.path;
      await expectLater(
        Isolate.run(() => readTagLib(path: path)),
        throwsFormatException,
      );
      await file.delete();
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test(
    'native FD extraction borrows readonly handles and rejects writable ones',
    () async {
      final libc = DynamicLibrary.open('libc.so.6');
      final open = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('open');
      final close = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      final seek = libc
          .lookupFunction<
            Int64 Function(Int32, Int64, Int32),
            int Function(int, int, int)
          >('lseek');
      final directory = await Directory.systemTemp.createTemp(
        'motif-taglib-fd-',
      );
      try {
        final file = File('${directory.path}/borrowed.wav');
        await file.writeAsBytes(wavFixture(tagged: true));
        final path = file.path.toNativeUtf8();
        try {
          for (final access in [0, 2]) {
            // POSIX O_RDONLY, O_RDWR
            final fd = open(path, access);
            expect(fd, greaterThanOrEqualTo(0));
            try {
              if (access == 0) {
                for (var i = 0; i < 3; i++) {
                  final tags = await Isolate.run(
                    () => readTagLib(descriptor: fd),
                  );
                  expect(tags['title'], 'A "song"');
                  expect(tags['durationMs'], 1000);
                  expect(seek(fd, 0, 0), 0); // Borrowed FD is still valid.
                }
              } else {
                await expectLater(
                  Isolate.run(() => readTagLib(descriptor: fd)),
                  throwsFormatException,
                );
                expect(seek(fd, 0, 0), 0);
              }
            } finally {
              close(fd);
            }
          }
        } finally {
          malloc.free(path);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isLinux,
  );
}

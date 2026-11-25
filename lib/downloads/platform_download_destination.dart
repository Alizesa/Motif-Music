import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'download_destination.dart';

final class PlatformDownloadDestination implements DownloadDestination {
  const PlatformDownloadDestination();
  static const channel = MethodChannel('motif/downloads');

  @override
  Future<DownloadDirectory?> chooseDirectory() async {
    if (Platform.isAndroid) {
      return const SafDownloadDestination().chooseDirectory();
    }
    final uri = await FilePicker.pickDirectory(dialogTitle: '选择下载保存目录');
    return uri == null ? null : DownloadDirectory(uri, uri.toFilePath());
  }

  @override
  Future<DownloadWriter> create(DownloadDirectory directory) async {
    if (Platform.isAndroid) {
      return const SafDownloadDestination().create(directory);
    }
    if (!Platform.isWindows || directory.uri.scheme != 'file') {
      throw const FileSystemException('Download directory unavailable');
    }
    return FileDownloadWriter.create(Directory.fromUri(directory.uri));
  }
}

final class SafDownloadDestination implements DownloadDestination {
  const SafDownloadDestination();
  static const _channel = PlatformDownloadDestination.channel;

  @override
  Future<DownloadDirectory?> chooseDirectory() async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'pickDirectory',
    );
    if (value == null) return null;
    final uri = Uri.parse(value['uri'] as String);
    if (uri.scheme != 'content' || uri.host.isEmpty) {
      throw const FileSystemException('Invalid download directory');
    }
    return DownloadDirectory(uri, value['label'] as String);
  }

  @override
  Future<DownloadWriter> create(DownloadDirectory directory) async {
    final id = await _channel.invokeMethod<String>('begin', {
      'directory': directory.uri.toString(),
    });
    if (id == null) {
      throw const FileSystemException('Download directory unavailable');
    }
    return _SafDownloadWriter(id);
  }
}

/// Uses MoveFileW without replacement: an existing destination is never removed,
/// even if another process creates it between the name check and commit.
final class FileDownloadWriter implements DownloadWriter {
  FileDownloadWriter._(this.file, this.output);
  final File file;
  RandomAccessFile? output;
  bool _finished = false;

  static Future<FileDownloadWriter> create(Directory directory) async {
    if (!await directory.exists()) {
      throw const FileSystemException('Directory unavailable');
    }
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final file = File(
      '${directory.path}${Platform.pathSeparator}.motif-$token.part',
    );
    await file.create(exclusive: true);
    try {
      return FileDownloadWriter._(
        file,
        await file.open(mode: FileMode.writeOnly),
      );
    } catch (_) {
      await file.delete();
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (bytes.length > 32768 || output == null) {
      throw const FileSystemException('Writer closed');
    }
    await output!.writeFrom(bytes);
  }

  @override
  Future<DownloadReceipt> finish(String basename, String extension) async {
    if (!const {'mp3', 'flac', 'wav'}.contains(extension) ||
        basename != downloadBasename(basename, const []) ||
        output == null) {
      throw const FileSystemException('Invalid download name');
    }
    await output!.flush();
    await output!.close();
    output = null;
    for (var index = 0; index < 1000; index++) {
      final name = '$basename${index == 0 ? '' : ' ($index)'}.$extension';
      final destination = '${file.parent.path}${Platform.pathSeparator}$name';
      if (_moveWithoutReplacement(file.path, destination)) {
        _finished = true;
        return DownloadReceipt(name, destination);
      }
    }
    throw const FileSystemException('No unused download name');
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    await output?.close();
    output = null;
    if (await file.exists()) await file.delete();
  }
}

final _kernel = DynamicLibrary.open('kernel32.dll');
final _move = _kernel
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('MoveFileW');

String _extendedPath(String path) {
  final normalized = path.replaceAll('/', r'\');
  return normalized.startsWith(r'\\?\')
      ? normalized
      : normalized.startsWith(r'\\')
      ? r'\\?\UNC\' + normalized.substring(2)
      : r'\\?\' + normalized;
}

bool _moveWithoutReplacement(String source, String destination) {
  final from = _extendedPath(source).toNativeUtf16();
  final to = _extendedPath(destination).toNativeUtf16();
  try {
    if (_move(from, to) != 0) return true;
    // Inspect only after the non-replacing move fails. A separate FFI call to
    // GetLastError can lose the thread-local error across a Dart transition.
    if (FileSystemEntity.typeSync(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return false;
    }
    throw const FileSystemException('Unable to save download');
  } finally {
    malloc.free(from);
    malloc.free(to);
  }
}

final class _SafDownloadWriter implements DownloadWriter {
  _SafDownloadWriter(this.id);
  final String id;
  static const _channel = PlatformDownloadDestination.channel;
  @override
  Future<void> write(Uint8List bytes) =>
      _channel.invokeMethod<void>('write', {'id': id, 'bytes': bytes});
  @override
  Future<void> abort() => _channel.invokeMethod<void>('abort', {'id': id});
  @override
  Future<DownloadReceipt> finish(String basename, String extension) async {
    final value = await _channel.invokeMapMethod<String, Object?>('finish', {
      'id': id,
      'name': basename,
      'extension': extension,
    });
    if (value == null) throw const FileSystemException('Download not saved');
    return DownloadReceipt(
      value['name'] as String,
      value['location'] as String,
    );
  }
}

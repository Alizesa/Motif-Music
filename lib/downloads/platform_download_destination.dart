import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'download_destination.dart';
import 'download_storage_error.dart';

final class PlatformDownloadDestination implements DownloadDestination {
  const PlatformDownloadDestination({this.windowsPicker});
  final Future<Uri?> Function()? windowsPicker;
  static const channel = MethodChannel('motif/downloads');

  @override
  Future<DownloadDirectory?> chooseDirectory() async {
    if (Platform.isAndroid) {
      return const SafDownloadDestination().chooseDirectory();
    }
    if (!Platform.isWindows) {
      throw const DownloadStorageException(DownloadStorageProblem.unavailable);
    }
    final pick =
        windowsPicker ??
        () => FilePicker.pickDirectory(dialogTitle: '选择下载保存目录');
    final uri = await pick();
    if (uri == null) return null;
    final selected = await restoreDirectory(uri);
    // Validate effective create/delete access on explicit selection only. Don't
    // overwrite a working preference just because a read-only folder exists.
    final probe = await FileDownloadWriter.create(_windowsFolder(selected.uri));
    await probe.abort();
    return selected;
  }

  @override
  Future<DownloadDirectory> restoreDirectory(Uri uri) async {
    if (Platform.isAndroid) {
      return const SafDownloadDestination().restoreDirectory(uri);
    }
    final folder = _windowsFolder(uri);
    if (!await folder.exists()) {
      throw const DownloadStorageException(DownloadStorageProblem.unavailable);
    }
    return DownloadDirectory(folder.uri, folder.path);
  }

  Directory _windowsFolder(Uri uri) {
    if (!Platform.isWindows || !isWindowsDownloadDirectoryUri(uri)) {
      throw const DownloadStorageException(DownloadStorageProblem.unavailable);
    }
    final folder = Directory.fromUri(uri);
    if (!folder.isAbsolute) {
      throw const DownloadStorageException(DownloadStorageProblem.unavailable);
    }
    return folder;
  }

  @override
  Future<DownloadWriter> create(DownloadDirectory directory) async {
    if (Platform.isAndroid) {
      return const SafDownloadDestination().create(directory);
    }
    return FileDownloadWriter.create(_windowsFolder(directory.uri));
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
    return _directory(value);
  }

  DownloadDirectory _directory(Map<String, Object?>? value, [Uri? expected]) {
    if (value case {'uri': String raw, 'label': String label}) {
      final uri = Uri.tryParse(raw);
      if (uri != null &&
          isSafDownloadDirectoryUri(uri) &&
          (expected == null || expected == uri)) {
        return DownloadDirectory(uri, label);
      }
    }
    throw const DownloadStorageException(DownloadStorageProblem.unavailable);
  }

  @override
  Future<DownloadDirectory> restoreDirectory(Uri uri) async {
    if (!isSafDownloadDirectoryUri(uri)) {
      throw const DownloadStorageException(DownloadStorageProblem.unavailable);
    }
    final value = await _channel.invokeMapMethod<String, Object?>(
      'restoreDirectory',
      {'directory': uri.toString()},
    );
    return _directory(value, uri);
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
      throw const DownloadStorageException(DownloadStorageProblem.unavailable);
    }
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final file = _child(directory, '.motif-$token.part');
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

  // Directory URIs from the picker already end with a separator. A second
  // separator may work with dart:io but is literal in MoveFileW's extended path.
  static File _child(Directory parent, String name) =>
      File.fromUri(parent.absolute.uri.resolveUri(Uri(pathSegments: [name])));

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
      final destination = _child(file.parent, name).path;
      if (_moveWithoutReplacement(file.path, destination)) {
        _finished = true;
        return DownloadReceipt(name, destination);
      }
    }
    throw const DownloadStorageException(DownloadStorageProblem.name);
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    try {
      await output?.close();
    } finally {
      output = null;
      if (await file.exists()) await file.delete();
    }
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

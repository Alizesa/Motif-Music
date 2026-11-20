import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../domain/audio_file_extensions.dart';
import '../domain/library_models.dart';
import 'library_platform_source.dart';

/// Windows directory picker and streaming filesystem traversal.
final class WindowsLibrarySource implements LibraryPlatformSource {
  const WindowsLibrarySource();

  @override
  LibraryPlatform get platform => LibraryPlatform.windows;

  @override
  Future<PickedLibraryDirectory?> pickDirectory() async {
    final uri = await FilePicker.pickDirectory(dialogTitle: '选择音乐目录');
    if (uri == null) return null;
    if (uri.scheme != 'file') {
      throw const LibraryTraversalException(
        'Windows directory picker returned a non-file URI.',
      );
    }

    final directory = Directory(uri.toFilePath(windows: true));
    return PickedLibraryDirectory(
      location: _directoryLocation(directory),
      displayName: _displayName(directory.path),
    );
  }

  @override
  Stream<List<ObservedAudioFile>> scanBatches(
    FileLocation root, {
    required LibraryScanCancellation cancellation,
  }) async* {
    if (root.platform != platform) {
      throw ArgumentError.value(root.platform, 'root.platform');
    }
    final rootUri = Uri.tryParse(root.locator);
    if (rootUri == null || rootUri.scheme != 'file') {
      throw const LibraryTraversalException('Invalid Windows directory URI.');
    }

    final rootDirectory = Directory(
      rootUri.toFilePath(windows: Platform.isWindows),
    );
    final rootKey = _canonicalPath(rootDirectory.path);
    final pendingDirectories = <Directory>[rootDirectory];
    var batch = <ObservedAudioFile>[];

    while (pendingDirectories.isNotEmpty) {
      cancellation.throwIfCancelled();
      final directory = pendingDirectories.removeLast();
      try {
        await for (final entity in directory.list(followLinks: false)) {
          cancellation.throwIfCancelled();
          if (entity is Directory) {
            pendingDirectories.add(entity);
            continue;
          }
          if (entity is! File ||
              !isSupportedAudioFileName(_fileName(entity.path))) {
            continue;
          }

          int? sizeBytes;
          int? modifiedMs;
          try {
            final stat = await entity.stat();
            if (stat.type == FileSystemEntityType.file) {
              sizeBytes = stat.size >= 0 ? stat.size : null;
              modifiedMs = stat.modified.millisecondsSinceEpoch;
            }
          } on FileSystemException {
            // Preserve membership even when an individual file's stat fails.
          }

          batch.add(
            ObservedAudioFile(
              location: _fileLocation(entity),
              fileName: _fileName(entity.path),
              sizeBytes: sizeBytes,
              modifiedMs: modifiedMs,
            ),
          );
          if (batch.length == libraryScanBatchLimit) {
            yield List.unmodifiable(batch);
            batch = <ObservedAudioFile>[];
          }
        }
      } on FileSystemException catch (error) {
        final failedPath = _canonicalPath(directory.path);
        throw LibraryTraversalException(
          'Cannot enumerate directory "${directory.path}": ${error.message}',
          rootAccessRevoked: failedPath == rootKey,
        );
      }
    }

    if (batch.isNotEmpty) yield List.unmodifiable(batch);
  }

  @override
  Future<void> releaseDirectory(FileLocation root) async {}

  static FileLocation _directoryLocation(Directory directory) {
    final uri = _fileUri(directory.path);
    return FileLocation(
      platform: LibraryPlatform.windows,
      key: _canonicalPath(directory.path),
      locator: uri.toString(),
    );
  }

  static FileLocation _fileLocation(File file) {
    final uri = _fileUri(file.path);
    return FileLocation(
      platform: LibraryPlatform.windows,
      key: _canonicalPath(file.path),
      locator: uri.toString(),
    );
  }

  static Uri _fileUri(String path) =>
      Uri.file(path, windows: Platform.isWindows).normalizePath();

  static String _canonicalPath(String path) =>
      _fileUri(path.toLowerCase()).toString();

  static String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;

  static String _displayName(String path) {
    final parts = path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}

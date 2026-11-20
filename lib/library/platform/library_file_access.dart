import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/library_models.dart';

/// Opens and closes a read handle without loading audio into Dart memory.
Future<void> verifyLibraryFileAccess(FileLocation location) async {
  switch (location.platform) {
    case LibraryPlatform.windows:
      final uri = Uri.parse(location.locator);
      if (uri.scheme != 'file') throw const FileSystemException('无效的本地文件地址');
      final handle = await File.fromUri(uri).open();
      await handle.close();
    case LibraryPlatform.android:
      final uri = Uri.parse(location.locator);
      if (uri.scheme != 'content' || uri.host.isEmpty) {
        throw const FileSystemException('无效的 Android 文件授权地址');
      }
      await const MethodChannel('motif/library_scanner')
          .invokeMethod<void>('checkFileAccess', {'uri': location.locator});
  }
}

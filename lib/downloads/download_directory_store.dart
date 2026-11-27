import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'download_destination.dart';

/// Only the explicitly picked directory locator is remembered. A stored URI
/// is not a permission: the destination must validate it before displaying it.
abstract interface class DownloadDirectoryStore {
  Future<Uri?> load();
  Future<void> save(Uri uri);
}

final class FileDownloadDirectoryStore implements DownloadDirectoryStore {
  const FileDownloadDirectoryStore(this.file);
  final Future<File> Function() file;
  static const _limit = 512 * 1024;

  @override
  Future<Uri?> load() async {
    final target = await file();
    if (!await target.exists()) return null;
    final input = await target.open();
    try {
      final bytes = await input.read(_limit + 1);
      if (bytes.length > _limit) {
        throw const FormatException('Directory preference size');
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data case {'version': 1, 'uri': String raw}) {
        final uri = Uri.tryParse(raw);
        if (uri != null && _valid(uri)) return uri;
      }
      throw const FormatException('Invalid directory preference');
    } finally {
      await input.close();
    }
  }

  @override
  Future<void> save(Uri uri) async {
    if (!_valid(uri)) throw const FormatException('Invalid directory locator');
    final bytes = utf8.encode(
      jsonEncode({'version': 1, 'uri': uri.toString()}),
    );
    if (bytes.length > _limit) {
      throw const FormatException('Directory preference size');
    }
    final target = await file();
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.${Random.secure().nextInt(1 << 31)}.tmp');
    await tmp.create(exclusive: true);
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  bool _valid(Uri uri) =>
      isWindowsDownloadDirectoryUri(uri) || isSafDownloadDirectoryUri(uri);
}

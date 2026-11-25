import 'dart:typed_data';

final class DownloadDirectory {
  const DownloadDirectory(this.uri, this.label);
  final Uri uri;
  final String label;
}

final class DownloadReceipt {
  const DownloadReceipt(this.name, this.location);
  final String name;
  final String location;
}

abstract interface class DownloadDestination {
  Future<DownloadDirectory?> chooseDirectory();
  Future<DownloadWriter> create(DownloadDirectory directory);
}

abstract interface class DownloadWriter {
  Future<void> write(Uint8List bytes);
  Future<DownloadReceipt> finish(String basename, String extension);
  Future<void> abort();
}

/// One portable path component; neither catalog text nor a script chooses paths.
String downloadBasename(String title, List<String> artists) {
  var name = [if (artists.isNotEmpty) artists.join('、'), title]
      .join(' - ')
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (name.isEmpty) name = '歌曲';
  name = String.fromCharCodes(name.runes.take(100));
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return name;
}

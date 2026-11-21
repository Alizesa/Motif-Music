enum LibraryPlaybackErrorKind { notReady, busy, changed, unavailable }

class LibraryPlaybackException implements Exception {
  const LibraryPlaybackException(this.kind);
  final LibraryPlaybackErrorKind kind;

  @override
  String toString() => switch (kind) {
    LibraryPlaybackErrorKind.notReady => '无法读取本地曲库，请重试。',
    LibraryPlaybackErrorKind.busy => '曲库正在更新，请稍后重试。',
    LibraryPlaybackErrorKind.changed => '本地歌曲信息已更新，请重试。',
    LibraryPlaybackErrorKind.unavailable => '本地文件已变化或无法访问。',
  };
}

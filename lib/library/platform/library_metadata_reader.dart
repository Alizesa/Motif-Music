import '../domain/library_models.dart';

abstract interface class LibraryMetadataReader {
  /// Must release its handles before completing, including errors/cancellation.
  Future<TrackMetadata> read(LocalAudioFile file);
}

/// Missing stat fields never prove unchanged content. At least one comparable
/// stat is required; same-size/same-time replacements still need future hashing.
class MetadataFileState {
  const MetadataFileState({this.sizeBytes, this.modifiedMs});
  final int? sizeBytes;
  final int? modifiedMs;

  void verifyExpected(LocalAudioFile file) {
    if ((file.sizeBytes != null && file.sizeBytes != sizeBytes) ||
        (file.modifiedMs != null && file.modifiedMs != modifiedMs)) {
      throw const FormatException('文件状态已变化，请重新扫描目录');
    }
  }

  void verifyStable(MetadataFileState after) {
    if (sizeBytes != after.sizeBytes ||
        modifiedMs != after.modifiedMs ||
        (sizeBytes == null && modifiedMs == null)) {
      throw const FormatException('无法确认解析期间文件状态，请重新扫描或重试');
    }
  }
}

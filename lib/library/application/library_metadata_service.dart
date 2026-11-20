import '../data/library_repository.dart';
import '../domain/library_models.dart';
import '../platform/library_metadata_reader.dart';
import '../platform/library_platform_source.dart';

class MetadataProgress {
  const MetadataProgress({
    this.processed = 0,
    this.failed = 0,
    this.discarded = 0,
  });
  final int processed;
  final int failed;
  final int discarded;
}

/// One sequential, finite pass. The owner serializes passes, never FFI timeouts.
class LibraryMetadataService {
  const LibraryMetadataService(this.repository, this.reader);
  final LibraryRepository repository;
  final LibraryMetadataReader reader;

  Future<MetadataProgress> run({
    required LibraryScanCancellation cancellation,
    bool includeFailed = false,
    Future<void> Function(MetadataProgress)? onProgress,
  }) async {
    final upper = await repository.metadataUpperBound();
    var cursor = 0;
    var processed = 0;
    var failed = 0;
    var discarded = 0;
    while (cursor < upper && !cancellation.isCancelled) {
      final window = await repository.metadataWindow(
        afterId: cursor,
        throughId: upper,
        includeFailed: includeFailed,
      );
      cursor = window.afterId;
      for (final candidate in window.candidates) {
        if (cancellation.isCancelled) break;
        TrackMetadata tags;
        try {
          tags = await reader.read(candidate.file);
          if (tags.state != MetadataState.ready) {
            throw const FormatException('解析器未返回完整结果');
          }
        } catch (_) {
          tags = const TrackMetadata(state: MetadataState.failed);
        }
        // A cancellation never kills blocking native/provider work. Its late
        // result is consumed and handles released, without any database write.
        if (cancellation.isCancelled) break;
        final saved = await repository.writeMetadata(candidate, tags);
        if (saved) {
          processed++;
          if (tags.state == MetadataState.failed) failed++;
        } else {
          discarded++;
        }
        await onProgress?.call(
          MetadataProgress(
            processed: processed,
            failed: failed,
            discarded: discarded,
          ),
        );
      }
    }
    return MetadataProgress(
      processed: processed,
      failed: failed,
      discarded: discarded,
    );
  }
}

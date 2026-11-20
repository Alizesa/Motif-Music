import '../data/library_repository.dart';
import '../domain/library_models.dart';
import '../platform/library_platform_source.dart';

/// Coordinates platform enumeration with generation-safe bounded persistence.
final class LibraryScanService {
  const LibraryScanService(this._repository, this._source);

  final LibraryRepository _repository;
  final LibraryPlatformSource _source;

  Future<LibraryDirectory?> addDirectoryFromPicker() async {
    final picked = await _source.pickDirectory();
    if (picked == null) return null;
    if (picked.location.platform != _source.platform) {
      throw StateError('Directory picker returned a different platform.');
    }
    return _repository.addDirectory(
      location: picked.location,
      displayName: picked.displayName,
    );
  }

  Future<int> scanDirectory(
    int rootId, {
    LibraryScanCancellation? cancellation,
    void Function(int indexedFiles)? onProgress,
  }) async {
    final scanCancellation = cancellation ?? LibraryScanCancellation();
    scanCancellation.throwIfCancelled();
    final root = _findRoot(await _repository.directories(), rootId);
    if (root.location.platform != _source.platform) {
      throw StateError('No platform scanner is available for this directory.');
    }

    final session = await _repository.beginScan(rootId);
    var indexedFiles = 0;
    try {
      await for (final batch in _source.scanBatches(
        root.location,
        cancellation: scanCancellation,
      )) {
        scanCancellation.throwIfCancelled();
        if (batch.isEmpty || batch.length > LibraryRepository.maxBatchSize) {
          throw StateError(
            'Platform scanner must emit batches of 1 to '
            '${LibraryRepository.maxBatchSize} files.',
          );
        }
        await _repository.writeScanBatch(session, batch);
        indexedFiles += batch.length;
        onProgress?.call(indexedFiles);
      }
      scanCancellation.throwIfCancelled();
      await _repository.completeScan(session);
      return indexedFiles;
    } on LibraryScanCancelledException {
      await _repository.interruptScan(session);
      rethrow;
    } catch (error) {
      await _repository.failScan(
        session,
        accessRevoked:
            error is LibraryTraversalException && error.rootAccessRevoked,
      );
      rethrow;
    }
  }

  Future<void> removeDirectory(int rootId) async {
    final root = _findRootOrNull(await _repository.directories(), rootId);
    if (root == null) return;
    await _source.releaseDirectory(root.location);
    await _repository.removeDirectory(rootId);
  }

  static LibraryDirectory _findRoot(List<LibraryDirectory> roots, int rootId) =>
      _findRootOrNull(roots, rootId) ??
      (throw StateError('Directory does not exist: $rootId'));

  static LibraryDirectory? _findRootOrNull(
    List<LibraryDirectory> roots,
    int rootId,
  ) {
    for (final root in roots) {
      if (root.id == rootId) return root;
    }
    return null;
  }
}

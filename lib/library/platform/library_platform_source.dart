import 'dart:async';

import '../domain/library_models.dart';

const libraryScanBatchLimit = 200;

final class LibraryScanCancellation {
  final Completer<void> _cancelled = Completer<void>();

  final Set<void Function()> _listeners = {};

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Returns a disposer so completed batches retain no cancellation listeners.
  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (isCancelled) throw const LibraryScanCancelledException();
  }
}

final class LibraryScanCancelledException implements Exception {
  const LibraryScanCancelledException();

  @override
  String toString() => 'Library scan cancelled.';
}

class PickedLibraryDirectory {
  const PickedLibraryDirectory({
    required this.location,
    required this.displayName,
  });

  final FileLocation location;
  final String displayName;
}

/// A traversal failure ends the root scan; no missing-member cleanup is run.
class LibraryTraversalException implements Exception {
  const LibraryTraversalException(
    this.message, {
    this.rootAccessRevoked = false,
  });

  final String message;
  final bool rootAccessRevoked;

  @override
  String toString() => message;
}

/// Platform boundary for folder selection and bounded audio-file discovery.
abstract interface class LibraryPlatformSource {
  LibraryPlatform get platform;

  Future<PickedLibraryDirectory?> pickDirectory();

  /// Emits batches no larger than the repository write limit.
  Stream<List<ObservedAudioFile>> scanBatches(
    FileLocation root, {
    required LibraryScanCancellation cancellation,
  });

  /// Releases a persistent platform grant when the user removes a root.
  Future<void> releaseDirectory(FileLocation root);
}

import 'track_normalization.dart';

enum LibraryPlatform { windows, android }

enum MetadataState { pending, ready, failed }

enum MatchDecision { manual, automatic }

/// Platform adapters supply a canonical key independently of the playable URI.
/// Windows: canonical absolute path (Windows-aware casing); Android: provider
/// authority + document ID, not a tree-specific URI or display filename.
class FileLocation {
  const FileLocation({
    required this.platform,
    required this.key,
    required this.locator,
  });

  final LibraryPlatform platform;
  final String key;
  final String locator;
}

class LibraryDirectory {
  const LibraryDirectory({
    required this.id,
    required this.location,
    required this.displayName,
    required this.isAccessible,
    required this.scanGeneration,
    required this.activeGeneration,
    required this.lastScanState,
  });

  final int id;
  final FileLocation location;
  final String displayName;
  final bool isAccessible;
  final int scanGeneration;
  final int? activeGeneration;
  final String lastScanState;
}

class ScanSession {
  const ScanSession({required this.rootId, required this.generation});

  final int rootId;
  final int generation;
}

class TrackMetadata {
  const TrackMetadata({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.durationMs,
    this.container,
    this.codec,
    this.state = MetadataState.ready,
  });

  final String title;
  final String artist;
  final String album;
  final int? durationMs;
  final String? container;
  final String? codec;
  final MetadataState state;
}

/// Null metadata preserves unchanged tags, but clears stale tags on stat change.
class ObservedAudioFile {
  const ObservedAudioFile({
    required this.location,
    required this.fileName,
    this.sizeBytes,
    this.modifiedMs,
    this.metadata,
  });

  final FileLocation location;
  final String fileName;
  final int? sizeBytes;
  final int? modifiedMs;
  final TrackMetadata? metadata;
}

class LocalAudioFile {
  const LocalAudioFile({
    required this.id,
    required this.location,
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.metadata,
    required this.revision,
    required this.normalizationVersion,
    required this.isPresent,
  });

  final int id;
  final FileLocation location;
  final String fileName;
  final int? sizeBytes;
  final int? modifiedMs;
  final TrackMetadata metadata;
  final int revision;
  final int normalizationVersion;
  final bool isPresent;

  String get displayTitle =>
      metadata.title.trim().isEmpty ? fileName : metadata.title;
}

/// A bounded extraction snapshot tied to one accessible directory generation.
class MetadataCandidate {
  const MetadataCandidate({
    required this.file,
    required this.rootId,
    required this.scanGeneration,
  });

  final LocalAudioFile file;
  final int rootId;
  final int scanGeneration;
}

class FileScanState {
  const FileScanState({
    required this.key,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.metadataState,
    required this.normalizationVersion,
    required this.isPresent,
  });

  final String key;
  final int? sizeBytes;
  final int? modifiedMs;
  final MetadataState metadataState;
  final int normalizationVersion;
  final bool isPresent;

  bool needsMetadata({required int? sizeBytes, required int? modifiedMs}) =>
      !isPresent ||
      normalizationVersion != TrackNormalization.version ||
      sizeBytes == null ||
      modifiedMs == null ||
      this.sizeBytes != sizeBytes ||
      this.modifiedMs != modifiedMs ||
      metadataState != MetadataState.ready;
}

/// Both result sets are bounded; unknown-duration files require separate review.
/// A truncated result MUST NOT be treated as a unique automatic match.
class MatchCandidates {
  MatchCandidates({
    required List<LocalAudioFile> timed,
    required List<LocalAudioFile> unmeasured,
    required this.isTruncated,
  }) : timed = List.unmodifiable(timed),
       unmeasured = List.unmodifiable(unmeasured);

  final List<LocalAudioFile> timed;
  final List<LocalAudioFile> unmeasured;
  final bool isTruncated;
}

class MetadataWindow {
  MetadataWindow({
    required this.afterId,
    required List<MetadataCandidate> candidates,
  }) : candidates = List.unmodifiable(candidates);
  final int afterId;
  final List<MetadataCandidate> candidates;
}

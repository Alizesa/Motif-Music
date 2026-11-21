import '../../settings/playback_quality_settings.dart';
import 'audio_quality.dart';
import 'library_models.dart';
import 'track_normalization.dart';

enum LocalPlaybackStatus { selected, needsConfirmation, noMatch }

enum LocalPlaybackReason {
  uniqueVersion,
  onlineQuality,
  highestQuality,
  incompleteMetadata,
  conflictingMetadata,
  ambiguousQuality,
  missingOnlineQuality,
  truncatedCandidates,
  noCandidates,
}

class LocalPlaybackResolution {
  LocalPlaybackResolution({
    required this.status,
    required this.reason,
    required List<LocalAudioFile> candidates,
    this.selected,
    this.isTruncated = false,
  }) : candidates = List.unmodifiable(candidates);

  final LocalPlaybackStatus status;
  final LocalPlaybackReason reason;
  final LocalAudioFile? selected;
  final List<LocalAudioFile> candidates;
  final bool isTruncated;
}

/// Identity checks precede quality selection. No filenames, URLs or I/O here.
class LocalPlaybackMatcher {
  const LocalPlaybackMatcher();

  static const durationToleranceMs = 5000;
  static const version = 1;

  LocalPlaybackResolution resolve({
    required TrackMetadata track,
    required MatchCandidates candidates,
    required PlaybackQualityMode mode,
    AudioQuality? onlineQuality,
  }) {
    final verified = <LocalAudioFile>[];
    final uncertain = <LocalAudioFile>[];
    final conflicting = <LocalAudioFile>[];
    for (final file in [...candidates.timed, ...candidates.unmeasured]) {
      if (!file.isPresent ||
          file.metadata.state != MetadataState.ready ||
          file.normalizationVersion != TrackNormalization.version ||
          TrackNormalization.key(track.title).isEmpty ||
          TrackNormalization.key(file.metadata.title) !=
              TrackNormalization.key(track.title)) {
        continue;
      }
      switch (_identity(track, file.metadata)) {
        case _Identity.verified:
          verified.add(file);
        case _Identity.uncertain:
          uncertain.add(file);
        case _Identity.conflicting:
          conflicting.add(file);
      }
    }
    final review = [...verified, ...uncertain];
    final visible = review.isEmpty ? conflicting : review;
    LocalPlaybackResolution confirm(LocalPlaybackReason reason) =>
        LocalPlaybackResolution(
          status: LocalPlaybackStatus.needsConfirmation,
          reason: reason,
          candidates: visible,
          isTruncated: candidates.isTruncated,
        );
    LocalPlaybackResolution select(
      LocalAudioFile file,
      LocalPlaybackReason reason,
    ) => LocalPlaybackResolution(
      status: LocalPlaybackStatus.selected,
      reason: reason,
      candidates: visible,
      selected: file,
    );
    if (candidates.isTruncated) {
      return confirm(LocalPlaybackReason.truncatedCandidates);
    }
    if (visible.isEmpty) {
      return LocalPlaybackResolution(
        status: LocalPlaybackStatus.noMatch,
        reason: LocalPlaybackReason.noCandidates,
        candidates: const [],
      );
    }
    if (uncertain.isNotEmpty) {
      return confirm(LocalPlaybackReason.incompleteMetadata);
    }
    if (verified.isEmpty) {
      return confirm(LocalPlaybackReason.conflictingMetadata);
    }
    // Quality preference only distinguishes multiple reliable local versions.
    if (verified.length == 1) {
      return select(verified.single, LocalPlaybackReason.uniqueVersion);
    }
    if (mode == PlaybackQualityMode.followOnline) {
      if (onlineQuality == null || !onlineQuality.hasKnownMetric) {
        return confirm(LocalPlaybackReason.missingOnlineQuality);
      }
      final comparisons = verified
          .map((file) => file.quality.compareTo(onlineQuality))
          .toList();
      final matches = [
        for (var i = 0; i < verified.length; i++)
          if (comparisons[i] == QualityComparison.equal) verified[i],
      ];
      if (matches.length == 1 &&
          !comparisons.contains(QualityComparison.incomparable)) {
        return select(matches.single, LocalPlaybackReason.onlineQuality);
      }
    } else {
      final highest = verified
          .where(
            (file) => verified.every(
              (other) =>
                  identical(file, other) ||
                  file.quality.compareTo(other.quality) ==
                      QualityComparison.better,
            ),
          )
          .toList();
      if (highest.length == 1) {
        return select(highest.single, LocalPlaybackReason.highestQuality);
      }
    }
    return confirm(LocalPlaybackReason.ambiguousQuality);
  }

  static _Identity _identity(TrackMetadata track, TrackMetadata local) {
    var incomplete = false;
    for (final pair in [
      (track.artist, local.artist),
      (track.album, local.album),
    ]) {
      final requested = TrackNormalization.key(pair.$1);
      final actual = TrackNormalization.key(pair.$2);
      if (requested.isNotEmpty && actual.isNotEmpty && requested != actual) {
        return _Identity.conflicting;
      }
      if (requested.isEmpty != actual.isEmpty) incomplete = true;
    }
    // A title and duration without a singer do not prove song identity.
    if (TrackNormalization.key(track.artist).isEmpty) incomplete = true;
    final requested = track.durationMs;
    final actual = local.durationMs;
    if (requested == null || actual == null || requested <= 0 || actual <= 0) {
      incomplete = true;
    } else if ((requested - actual).abs() > durationToleranceMs) {
      return _Identity.conflicting;
    }
    return incomplete ? _Identity.uncertain : _Identity.verified;
  }
}

enum _Identity { verified, uncertain, conflicting }

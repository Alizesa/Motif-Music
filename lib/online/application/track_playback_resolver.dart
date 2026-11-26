import '../../audio/controlled_pcm.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import '../../library/domain/audio_quality.dart';
import '../../library/domain/library_models.dart';
import '../../library/domain/library_playback_error.dart';
import '../../library/domain/local_playback_matcher.dart';
import '../domain/music_source_registry.dart';
import '../domain/playback_source.dart';
import '../qq/qq_track.dart';

sealed class LocalPlaybackChoice {
  const LocalPlaybackChoice();
  const factory LocalPlaybackChoice.file(int id) = ChooseLocalFile;
  const factory LocalPlaybackChoice.online() = ChooseOnline;
}

class ChooseLocalFile extends LocalPlaybackChoice {
  const ChooseLocalFile(this.id);
  final int id;
}

class ChooseOnline extends LocalPlaybackChoice {
  const ChooseOnline();
}

typedef ConfirmLocalPlayback = Future<LocalPlaybackChoice?> Function(
  QqTrack track,
  LocalPlaybackResolution resolution,
);

class ResolvedPlaybackTrack {
  const ResolvedPlaybackTrack({required this.uri, this.localFile, this.stream});

  final String uri;
  final LocalAudioFile? localFile;
  final OnlineStream? stream;
}

class PlaybackCancelled implements Exception {
  const PlaybackCancelled();
}

/// Resolve local identity and recheck access before asking for any stream URL.
/// Request tiers and file sizes never stand in for measured audio quality.
class TrackPlaybackResolver {
  const TrackPlaybackResolver({
    required this.sources,
    required this.matchLocal,
    required this.prepareLocal,
  });

  final MusicSourceRegistry sources;
  final Future<LocalPlaybackResolution> Function(
    QqTrack track,
    AudioQuality? reportedQuality,
  )
  matchLocal;
  final Future<LocalAudioFile> Function(LocalAudioFile file) prepareLocal;

  Future<ResolvedPlaybackTrack> resolve(
    QqTrack track,
    OnlineQuality quality, {
    required ConfirmLocalPlayback confirm,
    required bool Function() isCurrent,
    String preferredSourceId = 'qq',
    String? fallbackSourceId,
    AudioQuality? reportedQuality,
    PcmCancellation? cancellation,
    DiagnosticTrace? trace,
  }) async {
    void checkCurrent() {
      if (!isCurrent()) throw const PlaybackCancelled();
    }

    checkCurrent();
    final local = await matchLocal(track, reportedQuality);
    checkCurrent();
    trace?.record(DiagnosticEvent.localMatch, {
      DiagnosticField.state: local.status,
      DiagnosticField.reason: local.reason,
      DiagnosticField.candidates: local.candidates.length,
    });
    LocalAudioFile? chosen = local.selected;
    if (local.status == LocalPlaybackStatus.needsConfirmation) {
      final choice = await confirm(track, local);
      checkCurrent();
      if (choice == null) throw const PlaybackCancelled();
      if (choice case ChooseLocalFile(:final id)) {
        final matches = local.candidates.where((file) => file.id == id);
        if (matches.length != 1) throw const PlaybackCancelled();
        chosen = matches.single;
      }
    }
    if (chosen != null) {
      try {
        final prepared = await prepareLocal(chosen);
        checkCurrent();
        return ResolvedPlaybackTrack(
          uri: prepared.location.locator,
          localFile: prepared,
        );
      } on LibraryPlaybackException catch (error) {
        checkCurrent();
        if (error.kind != LibraryPlaybackErrorKind.unavailable) rethrow;
        trace?.record(DiagnosticEvent.localFallback, {
          DiagnosticField.reason: error.kind,
        });
        // A disappeared file may fall back online; a busy/failed index may not.
      }
    }
    checkCurrent();
    final stream = await sources.resolve(
      track,
      quality,
      preferredSourceId: preferredSourceId,
      fallbackSourceId: fallbackSourceId,
      checkActive: checkCurrent,
      cancellation: cancellation,
      trace: trace,
    );
    return ResolvedPlaybackTrack(uri: stream.uri.toString(), stream: stream);
  }
}

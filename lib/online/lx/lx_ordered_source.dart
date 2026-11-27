import 'dart:async';

import '../../audio/controlled_pcm.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import '../domain/download_source.dart';
import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../qq/qq_track.dart';
import 'lx_music_platform.dart';
import 'lx_audio_check.dart';
import 'lx_request_error.dart';

const lxOrderedSourceId = 'lx:ordered';

/// A non-null platform requests one checked candidate, not a nested platform search.
abstract interface class OrderedLxSource
    implements CancellablePlaybackSource, TrackDownloadSource {
  bool supports(LxPlatform platform, OnlineQuality quality);

  @override
  Future<OnlineStream> resolveCancellable(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation cancellation, {
    DiagnosticTrace? trace,
    LxPlatform? onlyPlatform,
  });

  @override
  Future<String> transfer(
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
    DiagnosticTrace? trace,
    LxPlatform? onlyPlatform,
  });
}

bool _canTryNext(OnlineException error) {
  if (error is LxRequestException &&
      const {
        LxRequestFailure.tls,
        LxRequestFailure.apiAddress,
        LxRequestFailure.mediaAddress,
        LxRequestFailure.privateAddress,
        LxRequestFailure.headers,
      }.contains(error.reason)) {
    return false;
  }
  return const {
    OnlineErrorKind.unavailable,
    OnlineErrorKind.unsupported,
    OnlineErrorKind.unsupportedQuality,
    OnlineErrorKind.unsupportedFormat,
    OnlineErrorKind.unsupportedRequest,
    OnlineErrorKind.scriptFailed,
    OnlineErrorKind.transport,
  }.contains(error.kind);
}

/// Keep QQ and other explicitly selected providers in position. Within each
/// uninterrupted run of scripts, exhaust the original platform before matching
/// another one, just as for a script-only download.
Iterable<(PlaybackUrlResolver, LxPlatform?)> _candidates(
  List<PlaybackUrlResolver> sources,
  OnlineQuality quality,
) sync* {
  var i = 0;
  while (i < sources.length) {
    final source = sources[i];
    if (source is! OrderedLxSource) {
      yield (source, null);
      i++;
      continue;
    }
    final start = i;
    while (i < sources.length && sources[i] is OrderedLxSource) {
      i++;
    }
    for (final p in LxPlatform.values) {
      for (var j = start; j < i; j++) {
        final script = sources[j] as OrderedLxSource;
        if (script.supports(p, quality)) yield (script, p);
      }
    }
  }
}

/// One deadline covers selection and validation, not an accepted file transfer.
Future<T> trySourceOrder<T>({
  required List<PlaybackUrlResolver> sources,
  required OnlineQuality quality,
  required bool Function(PlaybackUrlResolver) registered,
  required PcmCancellation owner,
  void Function()? checkActive,
  void Function(PlaybackUrlResolver, LxPlatform?)? onFallback,
  required Future<T> Function(
    PlaybackUrlResolver,
    LxPlatform?,
    PcmCancellation,
    void Function(),
  )
  attempt,
}) async {
  final work = PcmCancellation();
  final unlink = owner.listen(work.cancel);
  final timer = Timer(const Duration(seconds: 60), work.cancel);
  var accepted = false;
  void check() {
    checkActive?.call();
    owner.check();
    work.check();
  }

  void accept() {
    check();
    accepted = true;
    timer.cancel();
  }

  try {
    OnlineException? last;
    LxAudioCheckFailure? audioFailure;
    final failedScripts = <PlaybackUrlResolver>{};
    var attempted = false;
    for (final (source, platform) in _candidates(sources, quality)) {
      check();
      if (!registered(source) || failedScripts.contains(source)) continue;
      try {
        if (attempted) onFallback?.call(source, platform);
        attempted = true;
        final pending = attempt(source, platform, work, accept);
        final result = source is CancellablePlaybackSource
            ? await pending
            : await work.until(
                pending,
                discard: (late) {
                  if (late is ControlledOnlineStream) late.input.close();
                },
              );
        try {
          check();
          if (!registered(source)) {
            throw const OnlineException(OnlineErrorKind.closed);
          }
          return result;
        } catch (_) {
          if (result is ControlledOnlineStream) result.input.close();
          rethrow;
        }
      } on OnlineException catch (e) {
        check();
        if (accepted || !_canTryNext(e)) rethrow;
        if (e.kind == OnlineErrorKind.scriptFailed) failedScripts.add(source);
        if (e is LxAudioCheckFailure) audioFailure ??= e;
        last = e;
      }
    }
    check();
    throw audioFailure ??
        last ??
        OnlineException(
          sources.isEmpty
              ? OnlineErrorKind.unavailable
              : OnlineErrorKind.unsupportedQuality,
        );
  } on PcmCancelled {
    owner.check();
    if (!work.cancelled) rethrow;
    throw const LxRequestException(LxRequestFailure.scriptTimeout);
  } finally {
    timer.cancel();
    unlink();
    work.cancel();
  }
}

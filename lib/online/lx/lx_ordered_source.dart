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

/// Platform first, then the user's snapshotted script order. The timeout covers
/// selection and validation, not the subsequent transfer of an accepted file.
Future<T> tryOrderedLx<T>({
  required List<OrderedLxSource> scripts,
  required OnlineQuality quality,
  required bool Function(OrderedLxSource) registered,
  required PcmCancellation owner,
  void Function()? checkActive,
  void Function(OrderedLxSource, LxPlatform)? onFallback,
  required Future<T> Function(
    OrderedLxSource,
    LxPlatform,
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
    final failedScripts = <OrderedLxSource>{};
    var attempted = false;
    for (final platform in LxPlatform.values) {
      for (final script in scripts) {
        check();
        if (!registered(script) ||
            failedScripts.contains(script) ||
            !script.supports(platform, quality)) {
          continue;
        }
        try {
          if (attempted) onFallback?.call(script, platform);
          attempted = true;
          final result = await attempt(script, platform, work, accept);
          try {
            check();
            if (!registered(script)) {
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
          if (e.kind == OnlineErrorKind.scriptFailed) failedScripts.add(script);
          if (e is LxAudioCheckFailure) audioFailure ??= e;
          last = e;
        }
      }
    }
    check();
    throw audioFailure ??
        last ??
        OnlineException(
          scripts.isEmpty
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

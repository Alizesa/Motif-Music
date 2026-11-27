import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../audio/controlled_pcm.dart';
import '../../diagnostics/diagnostic_failure.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../qq/qq_track.dart';
import 'lx_music_platform.dart';
import 'lx_native_worker.dart';
import 'lx_network.dart';
import 'lx_platform_catalog.dart';
import 'lx_playback_source.dart';
import 'lx_request_error.dart';
import 'lx_source_store.dart';

typedef LxRun = Future<Map<String, Object?>> Function(
  Uint8List script, {
  required Map<String, String> info,
  Map<String, Object?>? event,
  required LxRequestHandler onRequest,
  required PcmCancellation cancellation,
});
typedef LxFetch = Future<Map<String, Object?>> Function(
  LxApiRequest,
  PcmCancellation,
);
typedef LxPublicDetail = Future<QqTrack> Function(
  String mid, {
  required int songType,
});

/// Resolves a URL for one enabled script revision. Does not own the queue,
/// open media, change the requested tier or select other imported scripts.
final class LxAddressResolver {
  const LxAddressResolver({
    required this.source,
    required this.store,
    required this.run,
    required this.fetch,
    required this.publicDetail,
    required this.catalog,
  });
  final LxStoredSource source;
  final LxSourceStore store;
  final LxRun run;
  final LxFetch fetch;
  final LxPublicDetail? publicDetail;
  final LxPlatformCatalog catalog;

  Future<Uri> resolve(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation work,
    DiagnosticTrace? trace,
  ) async {
    if (!source.qualities.contains(quality)) {
      throw const OnlineException(OnlineErrorKind.unsupportedQuality);
    }
    final scope = PcmCancellation();
    final detach = work.listen(scope.cancel);
    // One foreground deadline across metadata, all platform attempts and the
    // native queue. Each worker is still reaped before admitting another.
    final deadline = Timer(lxWorkerTimeout, scope.cancel);
    try {
      scope.check();
      final prepared = await _prepareTrack(track, quality, scope, trace);
      scope.check();
      final script = await store.read(source);
      scope.check();
      final quota = _LxApiQuota();
      OnlineException? firstFailure;
      for (final platform in LxPlatform.values) {
        if (!source.supports(platform, quality)) continue;
        scope.check();
        if (quota.full) throw const LxRequestException(LxRequestFailure.budget);
        try {
          Map<String, Object?>? music;
          if (platform == LxPlatform.tx) {
            music = lxQqMusicInfo(prepared);
          } else {
            trace?.record(DiagnosticEvent.lxPlatformMatch, {
              DiagnosticField.platform: platform,
              DiagnosticField.state: DiagnosticResult.started,
            });
            final LxPlatformMatch match;
            try {
              match = await catalog.match(platform, prepared, quality, scope);
            } on OnlineException catch (error) {
              trace?.record(DiagnosticEvent.lxPlatformMatch, {
                DiagnosticField.platform: platform,
                DiagnosticField.state: DiagnosticResult.failed,
                ...diagnosticFailure(error),
              });
              // An unreadable catalog isn't a script/runtime failure. Skip this
              // catalog only; cancellation, policy and cooldowns still stop.
              if (error.kind == OnlineErrorKind.malformedResponse) {
                continue;
              }
              rethrow;
            }
            scope.check();
            music = match.music;
            trace?.record(DiagnosticEvent.lxPlatformMatch, {
              DiagnosticField.platform: platform,
              DiagnosticField.reason: match.reason,
              DiagnosticField.cached: match.cached,
              DiagnosticField.state:
                  match.reason == LxMatchReason.insufficientMetadata
                  ? DiagnosticResult.skipped
                  : music == null
                  ? DiagnosticResult.mismatched
                  : DiagnosticResult.succeeded,
            });
            if (music == null) continue;
          }
          return await _scriptAddress(
            script,
            platform,
            music,
            quality,
            quota,
            scope,
            trace,
          );
        } on OnlineException catch (error) {
          scope.check();
          if (!const {
                OnlineErrorKind.unavailable,
                OnlineErrorKind.unsupported,
                OnlineErrorKind.unsupportedQuality,
                OnlineErrorKind.unsupportedRequest,
                OnlineErrorKind.transport,
              }.contains(error.kind) ||
              (error is LxRequestException &&
                  error.reason == LxRequestFailure.tls)) {
            rethrow;
          }
          firstFailure ??= error;
        }
      }
      throw firstFailure ?? const OnlineException(OnlineErrorKind.unavailable);
    } on PcmCancelled {
      work.check();
      throw const LxRequestException(LxRequestFailure.scriptTimeout);
    } finally {
      deadline.cancel();
      detach();
      scope.cancel();
    }
  }

  Future<Uri> _scriptAddress(
    LxScriptDocument script,
    LxPlatform platform,
    Map<String, Object?> music,
    OnlineQuality quality,
    _LxApiQuota quota,
    PcmCancellation work,
    DiagnosticTrace? trace,
  ) async {
    final broker = _LxRequestBudget(fetch, trace, quota);
    trace?.record(DiagnosticEvent.lxScript, {
      DiagnosticField.platform: platform,
      DiagnosticField.state: DiagnosticResult.started,
    });
    final Map<String, Object?> result;
    try {
      result = await run(
        script.bytes,
        info: script.info,
        event: {
          'source': platform.name,
          'action': 'musicUrl',
          'info': {'type': quality.lxValue, 'musicInfo': music},
        },
        onRequest: broker.request,
        cancellation: work,
      );
    } on OnlineException catch (error) {
      work.check();
      final failure = broker.terminal ?? error;
      trace?.record(DiagnosticEvent.lxScript, {
        DiagnosticField.platform: platform,
        DiagnosticField.state: DiagnosticResult.failed,
        ...diagnosticFailure(failure),
      });
      throw failure;
    } finally {
      broker.close();
    }
    work.check();
    final uri = checkedLxUrl(result['url']);
    trace?.record(DiagnosticEvent.lxScript, {
      DiagnosticField.platform: platform,
      if (broker.terminal case final error?) ...diagnosticFailure(error),
      if (uri == null && broker.terminal == null)
        DiagnosticField.reason: _scriptFailure(result['error']),
      DiagnosticField.state: uri == null || broker.terminal != null
          ? DiagnosticResult.failed
          : DiagnosticResult.succeeded,
    });
    if (broker.terminal != null) throw broker.terminal!;
    if (result['error'] == 'rateLimited') {
      throw const OnlineException(OnlineErrorKind.rateLimited);
    }
    if (result['error'] == 'cancelled') {
      throw const LxRequestException(LxRequestFailure.scriptCancelled);
    }
    if (uri != null) return uri;
    if (result.containsKey('url')) {
      throw const LxRequestException(LxRequestFailure.mediaAddress);
    }
    if (quota.full) throw const LxRequestException(LxRequestFailure.budget);
    if (!broker.admitted && broker.denied != null) throw broker.denied!;
    if (broker.lastTransportFailure case final failure?) throw failure;
    if (result['error'] == 'timeout') {
      throw const LxRequestException(LxRequestFailure.scriptTimeout);
    }
    throw OnlineException(switch (result['error']) {
      'unsupported' => OnlineErrorKind.unsupported,
      'unavailable' => OnlineErrorKind.unavailable,
      'init' || 'script' => OnlineErrorKind.scriptFailed,
      _ => OnlineErrorKind.operationRejected,
    });
  }

  Future<QqTrack> _prepareTrack(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation work,
    DiagnosticTrace? trace,
  ) async {
    final detail = publicDetail;
    if (detail == null ||
        (track.durationMs != null &&
            track.artists.isNotEmpty &&
            track.title.trim().isNotEmpty &&
            (!source.supports(LxPlatform.tx, quality) ||
                (track.mediaMid != null &&
                    track.qualitySizes.containsKey(quality))))) {
      trace?.record(DiagnosticEvent.lxCatalog, {
        DiagnosticField.state: DiagnosticResult.skipped,
      });
      return track;
    }
    work.check();
    trace?.record(DiagnosticEvent.lxCatalog, {
      DiagnosticField.state: DiagnosticResult.started,
    });
    try {
      // The public client owns caching, coalescing and rate limits. Do not let
      // a queued catalog lookup indefinitely delay or block script resolution.
      final extra = await work.until(
        detail(
          track.mid,
          songType: track.songType,
        ).timeout(const Duration(seconds: 5)),
      );
      work.check();
      if (extra.mid != track.mid ||
          (extra.songType != track.songType &&
              (extra.songId == null || extra.songId != track.songId)) ||
          (track.songId != null &&
              extra.songId != null &&
              extra.songId != track.songId)) {
        trace?.record(DiagnosticEvent.lxCatalog, {
          DiagnosticField.state: DiagnosticResult.mismatched,
        });
        return track;
      }
      trace?.record(DiagnosticEvent.lxCatalog, {
        DiagnosticField.state: DiagnosticResult.succeeded,
      });
      return QqTrack(
        mid: track.mid,
        title: track.title.trim().isEmpty ? extra.title : track.title,
        artists: track.artists.isEmpty ? extra.artists : track.artists,
        album: track.album.trim().isEmpty ? extra.album : track.album,
        songType: track.songType,
        songId: track.songId ?? extra.songId,
        albumMid: track.albumMid ?? extra.albumMid,
        mediaMid: track.mediaMid ?? extra.mediaMid,
        durationMs: track.durationMs ?? extra.durationMs,
        qualitySizes: {...extra.qualitySizes, ...track.qualitySizes},
      );
    } on Exception catch (error) {
      if (error is! OnlineException && error is! TimeoutException) rethrow;
      if (trace?.active == true) {
        trace!.record(DiagnosticEvent.lxCatalog, {
          DiagnosticField.state: DiagnosticResult.failed,
          ...diagnosticFailure(error),
        });
      }
      if (error is OnlineException &&
          const {
            OnlineErrorKind.rateLimited,
            OnlineErrorKind.rejected,
            OnlineErrorKind.closed,
            OnlineErrorKind.sessionChanged,
          }.contains(error.kind)) {
        rethrow;
      }
      // Some scripts can resolve the original sparse catalog row directly.
      return track;
    }
  }
}

enum _ScriptFailure {
  init,
  script,
  unsupported,
  unavailable,
  rateLimited,
  cancelled,
  timeout,
  unknown,
}

_ScriptFailure _scriptFailure(Object? raw) =>
    _ScriptFailure.values.where((v) => v.name == raw).firstOrNull ??
    _ScriptFailure.unknown;

final class _LxApiQuota {
  int used = 0;
  bool get full => used >= 4;
  void take() {
    if (full) throw const LxRequestException(LxRequestFailure.budget);
    used++;
  }
}

final class _LxRequestBudget {
  _LxRequestBudget(this.fetch, this.trace, this.quota);
  final _LxApiQuota quota;
  final LxFetch fetch;
  final DiagnosticTrace? trace;
  bool admitted = false;
  int _candidates = 0;
  final _active = <PcmCancellation>{};
  bool _closed = false;
  int _lastObservedCandidate = 0;
  OnlineException? lastTransportFailure;
  OnlineException? denied;
  OnlineException? terminal;

  void _observe(int candidate, OnlineException? failure) {
    // Report the newest admitted candidate's outcome even if an older HTTP
    // request finished later. The delivery order to the script is unaffected.
    if (candidate < _lastObservedCandidate) return;
    _lastObservedCandidate = candidate;
    lastTransportFailure = failure;
  }

  void _stop(OnlineException cause, PcmCancellation origin) {
    terminal ??= cause;
    for (final peer in _active.toList()) {
      if (!identical(peer, origin)) peer.cancel();
    }
  }

  void close() {
    _closed = true;
    for (final scope in _active.toList()) {
      scope.cancel();
    }
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> message,
    PcmCancellation cancellation,
  ) async {
    const refused = {'error': 'denied'};
    cancellation.check();
    if (_closed) throw const PcmCancelled();
    final candidate = ++_candidates;
    if (quota.full || terminal != null) {
      trace?.record(DiagnosticEvent.lxApiFailure, {
        DiagnosticField.candidate: candidate,
        DiagnosticField.reason: terminal?.kind ?? LxRequestFailure.budget,
      });
      return refused;
    }
    final uri = checkedLxUrl(message['url']);
    if (uri == null) {
      denied ??= const LxRequestException(LxRequestFailure.apiAddress);
      trace?.record(DiagnosticEvent.lxApiFailure, {
        DiagnosticField.candidate: candidate,
        DiagnosticField.reason: LxRequestFailure.apiAddress,
      });
      return refused;
    }
    final watch = trace?.active == true ? (Stopwatch()..start()) : null;
    var redirects = 0;
    final io = PcmCancellation();
    final detach = cancellation.listen(io.cancel);
    _active.add(io);
    try {
      final request = LxApiRequest.parse(
        message,
        onRedirect: () {
          io.check();
          quota.take();
          redirects++;
        },
      );
      quota.take();
      admitted = true;
      if (trace?.active == true) {
        trace!.record(DiagnosticEvent.lxApiStart, {
          DiagnosticField.candidate: candidate,
          DiagnosticField.inFlight: _active.length,
          DiagnosticField.timeoutMs: request.timeout.inMilliseconds,
        });
      }
      final response = await fetch(request, io);
      io.check();
      // Deliver upstream HTTP status to the callback, but do not let an
      // access refusal/rate limit cause more requests or platform rotation.
      switch (response['statusCode']) {
        case 401 || 403 || 407:
          _stop(const OnlineException(OnlineErrorKind.rejected), io);
        case 429:
          _stop(const OnlineException(OnlineErrorKind.rateLimited), io);
      }
      final result = {'response': response};
      if (watch != null) {
        final status = response['statusCode'];
        trace?.record(DiagnosticEvent.lxApiResponse, {
          DiagnosticField.candidate: candidate,
          DiagnosticField.elapsedMs: watch.elapsedMilliseconds,
          DiagnosticField.redirects: redirects,
          if (status is int && status >= 100 && status <= 599)
            DiagnosticField.status: status,
        });
      }
      _observe(candidate, null);
      // Reserve room for the exchange's one-use numeric ID in the same frame.
      if (utf8.encode(jsonEncode({...result, 'id': lxScriptCallLimit})).length >
          lxMessageLimit) {
        _stop(const OnlineException(OnlineErrorKind.malformedResponse), io);
        return refused;
      }
      return result;
    } on PcmCancelled catch (error) {
      _recordFailure(candidate, error, watch);
      rethrow;
    } on OnlineException catch (error) {
      io.check();
      _recordFailure(candidate, error, watch);
      if (error is LxRequestException &&
          const {
            LxRequestFailure.headers,
            LxRequestFailure.method,
            LxRequestFailure.body,
          }.contains(error.reason)) {
        denied = error;
      } else if (error.kind == OnlineErrorKind.transport) {
        _observe(candidate, error);
      } else {
        _stop(error, io);
      }
      return refused;
    } on IOException catch (error) {
      io.check();
      _recordFailure(candidate, error, watch);
      _observe(candidate, const LxRequestException(LxRequestFailure.connect));
      return refused;
    } on FormatException catch (error) {
      io.check();
      _recordFailure(candidate, error, watch);
      _stop(const OnlineException(OnlineErrorKind.malformedResponse), io);
      return refused;
    } finally {
      _active.remove(io);
      detach();
      io.cancel();
    }
  }

  void _recordFailure(int candidate, Object error, Stopwatch? watch) {
    if (trace?.active != true) return;
    trace!.record(DiagnosticEvent.lxApiFailure, {
      DiagnosticField.candidate: candidate,
      DiagnosticField.elapsedMs: watch?.elapsedMilliseconds,
      ...diagnosticFailure(error),
    });
  }
}

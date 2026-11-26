import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../audio/controlled_pcm.dart';
import '../../audio/controlled_encoded.dart';
import '../../diagnostics/diagnostic_failure.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import '../domain/music_source_registry.dart';
import '../domain/download_source.dart';
import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../qq/qq_track.dart';
import 'fixture/lx_fixture_wave.dart';
import 'lx_native_worker.dart';
import 'lx_audio_media.dart';
import 'lx_download.dart';
import 'lx_network.dart';
import 'lx_request_error.dart';
import 'lx_playback_source.dart';
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
typedef LxOpen = Future<ControlledAudioInput> Function(
  Uri,
  PcmCancellation,
  PcmCancellation,
);

typedef LxDownloadDetail = Future<QqTrack> Function(
  String mid, {
  required int songType,
});

typedef LxDownload = Future<String> Function(
  Uri,
  PcmCancellation,
  DownloadWrite,
  void Function(int),
);

final class LxSourceManager extends ChangeNotifier {
  LxSourceManager({
    required this.store,
    required this.registry,
    LxRun? run,
    LxFetch? fetch,
    this._open,
    this._download,
    this._downloadDetail,
  }) : _run = run ?? const LxNativeWorker().run,
       _fetch = fetch ?? const LxHttpsTransport().api;

  final LxSourceStore store;
  final MusicSourceRegistry registry;
  final LxRun _run;
  final LxFetch _fetch;
  final LxOpen? _open;
  final LxDownload? _download;
  final LxDownloadDetail? _downloadDetail;
  final _closing = PcmCancellation();
  Future<void>? _initializing;
  List<LxStoredSource> _sources = const [];
  List<LxStoredSource> get sources => _sources;
  bool _ready = false;
  bool get ready => _ready;
  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;

  Future<void> initialize() {
    if (_ready || _closing.cancelled) return Future.value();
    return _initializing ??= _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await store.load();
      if (_closing.cancelled) return;
      _apply(loaded);
      _ready = true;
      _error = null;
    } catch (_) {
      _error = '无法读取音源，请重试。';
    } finally {
      _initializing = null;
      _notify();
    }
  }

  Future<bool> import(Uint8List bytes, {String? replaceId}) =>
      _change(() async {
        final document = LxScriptDocument.parse(bytes);
        final previous = replaceId == null ? null : _byId(replaceId);
        if (_sources.any((item) => item.digest == document.digest)) {
          throw const _SourceChangeError('已导入相同内容的脚本。');
        }
        if (previous == null && _sources.length >= lxSourceCountLimit) {
          throw const _SourceChangeError('音源数量已达上限。');
        }
        // Import is the user's action to use this version. Validate without
        // networking before changing any existing source or playback lease.
        final capabilities = await _capabilities(document);
        _closing.check();
        final source = LxStoredSource.newScript(
          document,
          capabilities.qualities,
          previous,
        );
        await store.import(document);
        try {
          await _save([
            for (final item in _sources)
              if (item.id == replaceId) source else item,
            if (previous == null) source,
          ], revoke: previous);
        } catch (_) {
          await _discard(document.digest);
          rethrow;
        }
        if (previous != null) await _discard(previous.digest);
      });

  Future<bool> configure(String id, {required bool enable}) =>
      _change(() async {
        final current = _byId(id);
        var qualities = current.qualities;
        if (enable && !current.enabled) {
          final document = await store.read(current);
          final capabilities = await _capabilities(document);
          qualities = capabilities.qualities;
        }
        final next = current.configure(enabled: enable, qualities: qualities);
        await _save(_replace(next), revoke: current);
      });

  Future<bool> remove(String id) => _change(() async {
    final current = _byId(id);
    await _save(
      _sources.where((item) => item.id != id).toList(),
      revoke: current,
    );
    await _discard(current.digest);
  });

  Future<void> _discard(String digest) async {
    try {
      await store.discardBlob(digest);
    } on FileSystemException {
      // The source catalog no longer references these bytes.
    }
  }

  LxStoredSource _byId(String id) =>
      _sources.firstWhere((item) => item.id == id);
  List<LxStoredSource> _replace(LxStoredSource source) => [
    for (final item in _sources)
      if (item.id == source.id) source else item,
  ];

  Future<LxQqCapabilities> _capabilities(LxScriptDocument document) async {
    final result = await _run(
      document.bytes,
      info: document.info,
      onRequest: (_, _) async => const {'error': 'denied'},
      cancellation: _closing,
    );
    _closing.check();
    if (!result.containsKey('capabilities')) {
      throw const _SourceChangeError('脚本初始化失败。');
    }
    try {
      return LxQqCapabilities.fromInit(result['capabilities']);
    } on OnlineException {
      throw const _SourceChangeError('脚本未声明可用的 QQ 点播能力。');
    }
  }

  Future<bool> _change(Future<void> Function() change) async {
    if (_busy || _closing.cancelled) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      await initialize();
      if (!_ready) return false;
      _closing.check();
      await change();
      return true;
    } on _SourceChangeError catch (error) {
      _error = error.message;
      return false;
    } on FormatException {
      _error = '脚本格式有误。';
      return false;
    } catch (_) {
      _error = '无法更新音源，请重试。';
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _save(
    List<LxStoredSource> sources, {
    LxStoredSource? revoke,
  }) async {
    _closing.check();
    if (revoke != null) registry.revokeManaged(revoke.id);
    try {
      await store.save(sources);
    } catch (_) {
      if (!_closing.cancelled && revoke?.enabled == true) _register(revoke!);
      rethrow;
    }
    if (!_closing.cancelled) _apply(sources);
  }

  void _apply(List<LxStoredSource> next) {
    for (final source in _sources) {
      if (!next.any((item) => identical(item, source))) {
        registry.revokeManaged(source.id);
      }
    }
    _sources = List.unmodifiable(next);
    for (final source in next) {
      if (source.enabled && !registry.contains(source.id)) _register(source);
    }
  }

  void _register(LxStoredSource source) => registry.registerManaged(
    MusicSourceRegistration(
      name: source.name,
      resolver: _ManagedLxSource(
        source,
        store,
        _run,
        _fetch,
        _open,
        _download,
        _downloadDetail,
      ),
    ),
  );

  void _notify() {
    if (!_closing.cancelled) notifyListeners();
  }

  @override
  void dispose() {
    _closing.cancel();
    for (final source in _sources) {
      registry.revokeManaged(source.id);
    }
    super.dispose();
  }
}

Future<ControlledAudioInput> _openAudio(
  Uri uri,
  PcmCancellation owner,
  PcmCancellation request,
  DiagnosticTrace? trace,
) => openLxAudio(LxMediaTransport(uri, owner, trace: trace), request);

Future<String> _downloadAudio(
  Uri uri,
  PcmCancellation work,
  DownloadWrite write,
  void Function(int) onTotal,
  DiagnosticTrace? trace,
) => downloadLxAudio(
  LxMediaTransport.download(uri, work, trace: trace),
  work,
  write,
  onTotal,
);

final class _SourceChangeError implements Exception {
  const _SourceChangeError(this.message);
  final String message;
}

final class _ManagedLxSource
    implements CancellablePlaybackSource, TrackDownloadSource {
  _ManagedLxSource(
    this.source,
    this.store,
    this.run,
    this.fetch,
    this.open,
    this.download,
    this.downloadDetail,
  );

  final LxStoredSource source;
  final LxSourceStore store;
  final LxRun run;
  final LxFetch fetch;
  final LxOpen? open;
  final LxDownload? download;
  final LxDownloadDetail? downloadDetail;
  final _lifetime = PcmCancellation();
  static int _nextIdentity = 0;

  @override
  String get sourceId => source.id;

  @override
  Set<OnlineQuality> get downloadQualities => source.qualities;

  Future<Uri> _address(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation work,
    DiagnosticTrace? trace,
  ) async {
    if (!source.qualities.contains(quality)) {
      throw const OnlineException(OnlineErrorKind.unsupportedQuality);
    }
    work.check();
    final script = await store.read(source);
    work.check();
    final broker = _LxRequestBudget(fetch, trace);
    trace?.record(DiagnosticEvent.lxScript, {
      DiagnosticField.state: DiagnosticResult.started,
    });
    final result = await run(
      script.bytes,
      info: script.info,
      event: {
        'source': 'tx',
        'action': 'musicUrl',
        'info': {'type': quality.lxValue, 'musicInfo': lxQqMusicInfo(track)},
      },
      onRequest: broker.request,
      cancellation: work,
    );
    work.check();
    if (broker.terminal != null) throw broker.terminal!;
    final uri = checkedLxUrl(result['url']);
    trace?.record(DiagnosticEvent.lxScript, {
      DiagnosticField.state: uri == null
          ? DiagnosticResult.failed
          : DiagnosticResult.succeeded,
    });
    if (uri != null) return uri;
    if (result.containsKey('url')) {
      throw const LxRequestException(LxRequestFailure.mediaAddress);
    }
    if (!broker.admitted && broker.denied != null) throw broker.denied!;
    if (broker.transmissionFailed || result['error'] == 'timeout') {
      throw broker.lastTransportFailure ??
          const LxRequestException(LxRequestFailure.scriptTimeout);
    }
    throw OnlineException(switch (result['error']) {
      'unsupported' => OnlineErrorKind.unsupported,
      'unavailable' => OnlineErrorKind.unavailable,
      _ => OnlineErrorKind.operationRejected,
    });
  }

  Future<QqTrack> _prepareDownloadTrack(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation work,
    DiagnosticTrace? trace,
  ) async {
    final detail = downloadDetail;
    if (detail == null ||
        (track.mediaMid != null &&
            track.durationMs != null &&
            track.qualitySizes.containsKey(quality))) {
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
        title: track.title,
        artists: track.artists,
        album: track.album,
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
      // Some scripts can resolve the original sparse catalog row directly.
      return track;
    }
  }

  @override
  Future<String> transfer(
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
    DiagnosticTrace? trace,
  }) async {
    if (!source.qualities.contains(quality)) {
      throw const OnlineException(OnlineErrorKind.unsupportedQuality);
    }
    final work = PcmCancellation();
    final release = _lifetime.listen(work.cancel);
    final detach = cancellation.listen(work.cancel);
    try {
      final prepared = await _prepareDownloadTrack(track, quality, work, trace);
      final Uri uri;
      try {
        // The worker observes cancellation and reaps its process before returning.
        uri = await _address(prepared, quality, work, trace);
      } on OnlineException catch (error) {
        if (trace?.active == true) {
          trace!.record(
            DiagnosticEvent.sourceFailure,
            diagnosticFailure(error),
          );
        }
        if (error is LxRequestException ||
            (error.kind != OnlineErrorKind.unavailable &&
                error.kind != OnlineErrorKind.operationRejected)) {
          rethrow;
        }
        throw _DownloadAddressException(error.kind);
      }
      trace?.record(DiagnosticEvent.sourceReady);
      final override = download;
      final format = await (override == null
          ? _downloadAudio(uri, work, write, onTotal, trace)
          : override(uri, work, write, onTotal));
      trace?.record(DiagnosticEvent.lxMediaReady, {
        DiagnosticField.medium: switch (format) {
          'mp3' => DiagnosticMedium.mp3,
          'flac' => DiagnosticMedium.flac,
          'wav' => DiagnosticMedium.wave,
          _ => null,
        },
      });
      return format;
    } on PcmCancelled {
      if (cancellation.cancelled) rethrow;
      throw const OnlineException(OnlineErrorKind.closed);
    } on FixtureMediaException catch (error) {
      trace?.record(DiagnosticEvent.lxMediaFailure, {
        DiagnosticField.reason: error.kind,
      });
      throw OnlineException(switch (error.kind) {
        FixtureMediaFailure.format => OnlineErrorKind.unsupportedFormat,
        FixtureMediaFailure.denied => OnlineErrorKind.rejected,
        FixtureMediaFailure.range => OnlineErrorKind.malformedResponse,
        FixtureMediaFailure.transport ||
        FixtureMediaFailure.truncated => OnlineErrorKind.transport,
      });
    } finally {
      work.cancel();
      release();
      detach();
    }
  }

  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) =>
      resolveCancellable(track, quality, PcmCancellation());

  @override
  Future<OnlineStream> resolveCancellable(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation cancellation, {
    DiagnosticTrace? trace,
  }) async {
    if (!source.qualities.contains(quality)) {
      throw const OnlineException(OnlineErrorKind.unsupportedQuality);
    }
    final owner = PcmCancellation();
    final release = _lifetime.listen(owner.cancel);
    final work = PcmCancellation();
    final unlink = owner.listen(work.cancel);
    final detach = cancellation.listen(work.cancel);
    var handedOff = false;
    try {
      work.check();
      final uri = await _address(track, quality, work, trace);
      final override = open;
      final input = await work.until(
        override == null
            ? _openAudio(uri, owner, work, trace)
            : override(uri, owner, work),
        discard: (late) => late.close(),
      );
      final ControlledAudioInput owned;
      if (input is ControlledPcmInput) {
        owned = _OwnedInput(input, release);
      } else if (input is ControlledEncodedInput) {
        owned = _OwnedEncodedInput(input, release);
      } else {
        input.close();
        throw const OnlineException(OnlineErrorKind.unsupportedFormat);
      }
      handedOff = true;
      return ControlledOnlineStream(
        uri: Uri(
          scheme: 'motif-controlled',
          path: '$sourceId/${++_nextIdentity}',
        ),
        sourceId: sourceId,
        requestedQuality: quality,
        input: owned,
        owner: owner,
      );
    } on PcmCancelled {
      if (cancellation.cancelled) rethrow;
      if (_lifetime.cancelled) {
        throw const OnlineException(OnlineErrorKind.closed);
      }
      throw const OnlineException(OnlineErrorKind.transport);
    } on FixtureMediaException catch (error) {
      trace?.record(DiagnosticEvent.lxMediaFailure, {
        DiagnosticField.reason: error.kind,
      });
      throw OnlineException(switch (error.kind) {
        FixtureMediaFailure.format => OnlineErrorKind.unsupportedFormat,
        FixtureMediaFailure.transport ||
        FixtureMediaFailure.truncated => OnlineErrorKind.transport,
        FixtureMediaFailure.denied => OnlineErrorKind.rejected,
        _ => OnlineErrorKind.malformedResponse,
      });
    } on IOException {
      throw const OnlineException(OnlineErrorKind.transport);
    } finally {
      detach();
      unlink();
      if (!handedOff) {
        owner.cancel();
        release();
      }
    }
  }

  @override
  void close() => _lifetime.cancel();
}

final class _DownloadAddressException extends OnlineException {
  const _DownloadAddressException(super.kind);

  @override
  String toString() => kind == OnlineErrorKind.unavailable
      ? '所选音源未提供这首歌在该档位的下载地址。可换音源或音质。'
      : '获取下载地址失败：所选音源未能完成取址，请稍后重试。';
}

final class _LxRequestBudget {
  _LxRequestBudget(this.fetch, this.trace);
  final LxFetch fetch;
  final DiagnosticTrace? trace;
  int _requests = 0;
  int _candidates = 0;
  bool get admitted => _requests > 0;
  bool transmissionFailed = false;
  OnlineException? lastTransportFailure;
  OnlineException? denied;
  OnlineException? terminal;

  Future<Map<String, Object?>> request(
    Map<String, Object?> message,
    PcmCancellation cancellation,
  ) async {
    const refused = {'error': 'denied'};
    cancellation.check();
    final candidate = ++_candidates;
    if (_requests >= 4 || terminal != null) {
      trace?.record(DiagnosticEvent.lxApiFailure, {
        DiagnosticField.candidate: candidate,
        DiagnosticField.reason: _requests >= 4
            ? LxRequestFailure.budget
            : terminal?.kind,
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
    try {
      final request = LxApiRequest.parse(
        message,
        onRedirect: () {
          if (_requests >= 4) {
            throw const LxRequestException(LxRequestFailure.budget);
          }
          _requests++;
          redirects++;
        },
      );
      _requests++;
      final response = await fetch(request, cancellation);
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
      // A later valid response supersedes an earlier candidate's network
      // failure; parsing that response is the script's next decision.
      transmissionFailed = false;
      lastTransportFailure = null;
      if (utf8.encode(jsonEncode(result)).length > lxMessageLimit) {
        terminal = const OnlineException(OnlineErrorKind.malformedResponse);
        return refused;
      }
      return result;
    } on PcmCancelled {
      rethrow;
    } on OnlineException catch (error) {
      _recordFailure(candidate, error, watch);
      if (error is LxRequestException &&
          const {
            LxRequestFailure.headers,
            LxRequestFailure.method,
            LxRequestFailure.body,
          }.contains(error.reason)) {
        denied = error;
      } else if (error.kind == OnlineErrorKind.transport) {
        transmissionFailed = true;
        lastTransportFailure = error;
      } else {
        terminal = error;
      }
      return refused;
    } on IOException catch (error) {
      _recordFailure(candidate, error, watch);
      transmissionFailed = true;
      lastTransportFailure = const LxRequestException(LxRequestFailure.connect);
      return refused;
    } on FormatException catch (error) {
      _recordFailure(candidate, error, watch);
      terminal = const OnlineException(OnlineErrorKind.malformedResponse);
      return refused;
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

/// Unregister the source lease when a consumer finishes or discards the input.
final class _OwnedInput implements ControlledPcmInput {
  _OwnedInput(this.input, this.release);
  final ControlledPcmInput input;
  final void Function() release;
  @override
  int get channels => input.channels;
  @override
  int get sampleRate => input.sampleRate;
  @override
  int get frames => input.frames;
  @override
  bool get seekable => input.seekable;
  @override
  Future<ControlledPcmRead> openAt(int frame, PcmCancellation cancellation) =>
      input.openAt(frame, cancellation);
  @override
  void close() {
    release();
    input.close();
  }
}

final class _OwnedEncodedInput implements ControlledEncodedInput {
  _OwnedEncodedInput(this.input, this.release);
  final ControlledEncodedInput input;
  final void Function() release;
  @override
  ControlledAudioFormat get format => input.format;
  @override
  int get size => input.size;
  @override
  bool get seekable => input.seekable;
  @override
  Future<ControlledPcmRead> openAt(int offset, PcmCancellation cancellation) =>
      input.openAt(offset, cancellation);
  @override
  void close() {
    release();
    input.close();
  }
}

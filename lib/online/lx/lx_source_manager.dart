import 'dart:async';
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
import 'lx_address_resolver.dart';
import 'lx_source_store.dart';
import 'lx_music_platform.dart';
import 'lx_platform_catalog.dart';

typedef LxOpen = Future<ControlledAudioInput> Function(
  Uri,
  PcmCancellation,
  PcmCancellation,
);

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
    this._publicDetail,
    LxPlatformCatalog? catalog,
  }) : _catalog = catalog ?? LxPlatformCatalog(),
       _run = run ?? const LxNativeWorker().run,
       _fetch = fetch ?? const LxHttpsTransport().api;

  final LxSourceStore store;
  final MusicSourceRegistry registry;
  final LxRun _run;
  final LxFetch _fetch;
  final LxOpen? _open;
  final LxDownload? _download;
  final LxPublicDetail? _publicDetail;
  final LxPlatformCatalog _catalog;
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
      final loaded = await _upgradeCatalog(await store.load());
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

  /// Old manifests only remembered tx. Re-probe verified, enabled blobs
  /// offline without changing IDs or preferences. Bound startup work; entries
  /// not upgraded retain their old capabilities and can be retried later.
  Future<List<LxStoredSource>> _upgradeCatalog(
    List<LxStoredSource> loaded,
  ) async {
    if (!loaded.any((s) => s.enabled && s.needsProbe)) return loaded;
    final scope = PcmCancellation();
    final detach = _closing.listen(scope.cancel);
    final timer = Timer(const Duration(seconds: 5), scope.cancel);
    final next = loaded.toList();
    var changed = false;
    try {
      for (var i = 0; i < next.length && !scope.cancelled; i++) {
        final source = next[i];
        if (!source.enabled || !source.needsProbe) continue;
        try {
          final script = await store.read(source);
          scope.check();
          final caps = await _capabilities(script, scope);
          next[i] = source.configure(
            enabled: true,
            capabilities: caps,
            platform: source.platform,
            bumpVersion: false,
          );
          changed = true;
        } on Exception {
          // A failed upgrade must not revoke a previously usable tx channel.
        }
      }
      _closing.check();
      if (changed) {
        try {
          await store.save(next);
        } on FileSystemException {
          // Use the verified capabilities this session; retry saving next launch.
        }
      }
      return next;
    } finally {
      timer.cancel();
      detach();
      scope.cancel();
    }
  }

  Future<bool> import(Uint8List bytes, {String? replaceId}) => _change(
    () async {
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
      final pin = previous?.platform;
      if (pin != null && !capabilities.byPlatform.containsKey(pin)) {
        throw const _SourceChangeError('新脚本不支持当前固定通道。请先选“自动换源”，或作为新音源导入。');
      }
      final source = LxStoredSource.newScript(document, capabilities, previous);
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
    },
  );

  Future<bool> configure(String id, {required bool enable}) =>
      _change(() async {
        final current = _byId(id);
        final capabilities = enable && (!current.enabled || current.needsProbe)
            ? await _capabilities(await store.read(current))
            : current.capabilities;
        final next = current.configure(
          enabled: enable,
          capabilities: capabilities,
          platform: current.platform,
          needsProbe: current.needsProbe && !enable,
        );
        await _save(_replace(next), revoke: current);
      });

  Future<bool> selectPlatform(String id, LxPlatform? platform) =>
      _change(() async {
        final current = _byId(id);
        if (current.platform == platform) return;
        if (platform != null &&
            !current.capabilities.byPlatform.containsKey(platform)) {
          throw const _SourceChangeError('该脚本未声明此平台通道。');
        }
        // Stop the old lease before publishing a different routing policy.
        await _save(
          _replace(
            current.configure(
              enabled: current.enabled,
              capabilities: current.capabilities,
              needsProbe: current.needsProbe,
              platform: platform,
            ),
          ),
          revoke: current,
        );
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

  Future<LxMusicCapabilities> _capabilities(
    LxScriptDocument document, [
    PcmCancellation? scope,
  ]) async {
    final result = await _run(
      document.bytes,
      info: document.info,
      onRequest: (_, _) async => const {'error': 'denied'},
      cancellation: scope ?? _closing,
    );
    (scope ?? _closing).check();
    if (!result.containsKey('capabilities')) {
      throw const _SourceChangeError('脚本初始化失败。');
    }
    try {
      return LxMusicCapabilities.fromInit(result['capabilities']);
    } on OnlineException {
      throw const _SourceChangeError('脚本未声明可用的 QQ、酷我或酷狗 musicUrl 通道及音质。');
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
        LxAddressResolver(
          source: source,
          store: store,
          run: _run,
          fetch: _fetch,
          publicDetail: _publicDetail,
          catalog: _catalog,
        ),
        _open,
        _download,
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
  _ManagedLxSource(this.address, this.open, this.download);
  final LxAddressResolver address;
  LxStoredSource get source => address.source;
  final LxOpen? open;
  final LxDownload? download;
  final _lifetime = PcmCancellation();
  static int _nextIdentity = 0;

  @override
  String get sourceId => source.id;

  @override
  Set<OnlineQuality> get downloadQualities => source.qualities;

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
      final Uri uri;
      try {
        // The worker observes cancellation and reaps its process before returning.
        uri = await address.resolve(track, quality, work, trace);
      } on OnlineException catch (error) {
        if (trace?.active == true) {
          trace!.record(
            DiagnosticEvent.sourceFailure,
            diagnosticFailure(error),
          );
        }
        if (error is LxRequestException ||
            (error.kind != OnlineErrorKind.unavailable &&
                error.kind != OnlineErrorKind.operationRejected &&
                error.kind != OnlineErrorKind.scriptFailed)) {
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
      final uri = await address.resolve(track, quality, work, trace);
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

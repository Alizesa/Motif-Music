import '../../audio/controlled_pcm.dart';
import '../../diagnostics/diagnostic_failure.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import 'online_error.dart';
import 'download_source.dart';
import 'playback_source.dart';
import '../qq/qq_track.dart';
import '../lx/lx_ordered_source.dart';
import '../lx/lx_music_platform.dart';

class MusicSourceRegistration {
  const MusicSourceRegistration({required this.name, required this.resolver});

  final String name;
  final PlaybackUrlResolver resolver;
  String get id => resolver.sourceId;
}

/// Search identity always stays QQ. Only playback resolution is configurable.
class MusicSourceRegistry {
  MusicSourceRegistry({
    required PlaybackUrlResolver qq,
    List<MusicSourceRegistration> thirdPartySources = const [],
  }) : _builtIn = List.unmodifiable([
         MusicSourceRegistration(name: 'QQ 音乐', resolver: qq),
         ...thirdPartySources,
       ]) {
    if (qq.sourceId != 'qq' ||
        sources.any(
          (source) =>
              source.id.isEmpty ||
              source.id == lxOrderedSourceId ||
              source.name.trim().isEmpty,
        ) ||
        sources.map((source) => source.id).toSet().length != sources.length) {
      throw ArgumentError('Invalid source registrations');
    }
  }

  final List<MusicSourceRegistration> _builtIn;
  final Map<String, MusicSourceRegistration> _managed = {};
  List<MusicSourceRegistration> get sources =>
      List.unmodifiable([..._builtIn, ..._managed.values]);
  Future<void> Function()? loadManaged;
  List<MusicSourceRegistration> get downloadSources => List.unmodifiable(
    sources.where((source) => source.resolver is TrackDownloadSource),
  );

  List<MusicSourceRegistration> get orderableScripts => [
    for (final s in _managed.values)
      if (s.resolver is OrderedLxSource) s,
  ];

  List<OrderedLxSource> _ordered(List<String> ids) => [
    for (final id in ids.toSet())
      if (_managed[id]?.resolver case final OrderedLxSource script) script,
  ];

  Set<OnlineQuality> orderedQualities(List<String> ids) => {
    for (final s in _ordered(ids)) ...s.downloadQualities,
  };
  bool _registered(PlaybackUrlResolver s) =>
      identical(_managed[s.sourceId]?.resolver, s) ||
      _builtIn.any((item) => identical(item.resolver, s));

  /// A download never enrolls QQ or an unchecked script. Keep an explicit
  /// single-file provider if it is first; otherwise default to the LX list.
  String downloadDefault(String preferred, List<String>? backups) {
    if (backups == null || backups.isEmpty) return preferred;
    final available = {for (final s in downloadSources) s.id: s.resolver};
    // Disabling a checked script must not silently relax the remaining LX
    // candidate from validated sequential download to manual single-source mode.
    final hasScriptBackup = backups.any(
      (id) => !_builtIn.any((s) => s.id == id),
    );
    for (final id in [preferred, ...backups]) {
      final source = available[id];
      if (source == null) continue;
      if (source is! OrderedLxSource || (id == preferred && !hasScriptBackup)) {
        return id;
      }
      return lxOrderedSourceId;
    }
    return lxOrderedSourceId; // No eligible checked source; let the user choose.
  }

  Future<String> download(
    String sourceId,
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    DiagnosticTrace? trace,
    required DownloadWrite write,
    required void Function(int) onTotal,
    List<String> scriptOrder = const [],
  }) async {
    if (sourceId == lxOrderedSourceId) {
      return trySourceOrder(
        sources: _ordered(scriptOrder),
        quality: quality,
        owner: cancellation,
        registered: _registered,
        onFallback: (s, p) => _orderedFallback(trace, s.sourceId, quality, p),
        checkActive: () => _checkActive(null),
        attempt: (source, platform, work, accept) => _download(
          source.sourceId,
          track,
          quality,
          cancellation: work,
          trace: trace,
          onlyPlatform: platform,
          write: (bytes) {
            accept();
            return write(bytes);
          },
          onTotal: (n) {
            accept();
            onTotal(n);
          },
        ),
      );
    }
    return _download(
      sourceId,
      track,
      quality,
      cancellation: cancellation,
      trace: trace,
      write: write,
      onTotal: onTotal,
    );
  }

  Future<String> _download(
    String sourceId,
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
    DiagnosticTrace? trace,
    LxPlatform? onlyPlatform,
  }) async {
    _checkActive(null);
    cancellation.check();
    final source = downloadSources
        .where((item) => item.id == sourceId)
        .firstOrNull;
    if (source == null) throw const OnlineException(OnlineErrorKind.closed);
    final resolver = source.resolver as TrackDownloadSource;
    if (trace?.active == true) {
      trace!.record(
        DiagnosticEvent.sourceRequest,
        _sourceFacts(source.id, quality),
      );
    }
    final extension = onlyPlatform != null
        ? await (resolver as OrderedLxSource).transfer(
            track,
            quality,
            cancellation: cancellation,
            write: write,
            onTotal: onTotal,
            trace: trace,
            onlyPlatform: onlyPlatform,
          )
        : await resolver.transfer(
            track,
            quality,
            cancellation: cancellation,
            write: write,
            onTotal: onTotal,
            trace: trace,
          );
    _checkActive(null);
    cancellation.check();
    if (!sources.any((item) => identical(item, source))) {
      throw const OnlineException(OnlineErrorKind.closed);
    }
    return extension;
  }

  bool _closed = false;

  bool contains(String id) => sources.any((source) => source.id == id);

  String effectivePrimary(String id) =>
      id == lxOrderedSourceId || contains(id) ? id : 'qq';

  void registerManaged(MusicSourceRegistration source) {
    if (_closed ||
        source.id.isEmpty ||
        source.id == lxOrderedSourceId ||
        source.name.trim().isEmpty ||
        contains(source.id)) {
      source.resolver.close();
      throw StateError('LX registration unavailable');
    }
    _managed[source.id] = source;
  }

  void revokeManaged(String id) => _managed.remove(id)?.resolver.close();

  Future<OnlineStream> resolve(
    QqTrack track,
    OnlineQuality quality, {
    String preferredSourceId = 'qq',
    String? fallbackSourceId,
    List<String>? fallbackOrder,
    List<String> scriptOrder = const [],
    void Function()? checkActive,
    PcmCancellation? cancellation,
    DiagnosticTrace? trace,
  }) async {
    _checkActive(checkActive);
    cancellation?.check();
    final ensureSources = loadManaged;
    if (ensureSources != null &&
        (preferredSourceId != 'qq' ||
            fallbackSourceId != null ||
            (fallbackOrder?.isNotEmpty ?? false))) {
      await ensureSources();
      _checkActive(checkActive);
    }
    if (fallbackOrder != null && fallbackOrder.isEmpty) {
      if (!contains(preferredSourceId)) {
        throw const OnlineException(OnlineErrorKind.unavailable);
      }
      return _attempt(
        preferredSourceId,
        track,
        quality,
        checkActive,
        cancellation,
        trace,
      );
    }
    if (fallbackOrder != null || preferredSourceId == lxOrderedSourceId) {
      final registrations = {for (final s in sources) s.id: s.resolver};
      final selected = fallbackOrder == null
          ? _ordered(scriptOrder)
          : <PlaybackUrlResolver>[
              for (final id in {preferredSourceId, ...fallbackOrder})
                ?registrations[id],
            ];
      return trySourceOrder(
        sources: selected,
        quality: quality,
        owner: cancellation ?? PcmCancellation(),
        registered: _registered,
        onFallback: (s, p) => _orderedFallback(trace, s.sourceId, quality, p),
        checkActive: () => _checkActive(checkActive),
        attempt: (s, p, work, _) => _attempt(
          s.sourceId,
          track,
          quality,
          checkActive,
          work,
          trace,
          onlyPlatform: p,
        ),
      );
    }
    final primary = effectivePrimary(preferredSourceId);
    final fallback =
        fallbackSourceId != primary &&
            fallbackSourceId != null &&
            contains(fallbackSourceId)
        ? fallbackSourceId
        : null;
    try {
      return await _attempt(
        primary,
        track,
        quality,
        checkActive,
        cancellation,
        trace,
      );
    } on OnlineException catch (error) {
      _checkActive(checkActive);
      cancellation?.check();
      // Account rejection and cooldowns must not become a fallback loop.
      if (fallback == null ||
          !{
            OnlineErrorKind.unavailable,
            OnlineErrorKind.unsupported,
            OnlineErrorKind.unsupportedFormat,
            OnlineErrorKind.unsupportedQuality,
            OnlineErrorKind.unsupportedRequest,
            OnlineErrorKind.scriptFailed,
            OnlineErrorKind.transport,
          }.contains(error.kind)) {
        rethrow;
      }
      if (trace?.active == true) {
        trace!.record(
          DiagnosticEvent.sourceFallback,
          _sourceFacts(fallback, quality),
        );
      }
      return _attempt(
        fallback,
        track,
        quality,
        checkActive,
        cancellation,
        trace,
      );
    }
  }

  void _orderedFallback(
    DiagnosticTrace? trace,
    String id,
    OnlineQuality quality,
    LxPlatform? platform,
  ) {
    if (trace?.active == true) {
      trace!.record(DiagnosticEvent.sourceFallback, {
        ..._sourceFacts(id, quality),
        DiagnosticField.platform: ?platform,
      });
    }
  }

  DiagnosticFacts _sourceFacts(String id, OnlineQuality quality) => {
    DiagnosticField.source: id == 'qq'
        ? DiagnosticSource.qq
        : _managed.containsKey(id)
        ? DiagnosticSource.lx
        : DiagnosticSource.other,
    // List position (1-based), never a user-chosen name, ID, or script hash.
    DiagnosticField.sourceIndex:
        sources.indexWhere((source) => source.id == id) + 1,
    DiagnosticField.quality: quality,
  };

  Future<OnlineStream> _attempt(
    String id,
    QqTrack track,
    OnlineQuality quality,
    void Function()? checkActive,
    PcmCancellation? cancellation,
    DiagnosticTrace? trace, {
    LxPlatform? onlyPlatform,
  }) async {
    final facts = trace?.active == true ? _sourceFacts(id, quality) : null;
    if (facts != null) trace!.record(DiagnosticEvent.sourceRequest, facts);
    try {
      final stream = await _resolve(
        id,
        track,
        quality,
        checkActive,
        cancellation,
        trace,
        onlyPlatform: onlyPlatform,
      );
      trace?.record(DiagnosticEvent.sourceReady);
      return stream;
    } on OnlineException catch (error) {
      if (trace?.active == true) {
        trace!.record(DiagnosticEvent.sourceFailure, diagnosticFailure(error));
      }
      rethrow;
    }
  }

  Future<OnlineStream> _resolve(
    String id,
    QqTrack track,
    OnlineQuality quality,
    void Function()? checkActive,
    PcmCancellation? cancellation,
    DiagnosticTrace? trace, {
    LxPlatform? onlyPlatform,
  }) async {
    _checkActive(checkActive);
    cancellation?.check();
    final managed = _managed[id];
    final source =
        managed ?? _builtIn.where((source) => source.id == id).firstOrNull;
    if (source == null) throw const OnlineException(OnlineErrorKind.closed);
    final resolver = source.resolver;
    final stream = onlyPlatform != null
        ? await (resolver as OrderedLxSource).resolveCancellable(
            track,
            quality,
            cancellation!,
            trace: trace,
            onlyPlatform: onlyPlatform,
          )
        : resolver is CancellablePlaybackSource
        ? await resolver.resolveCancellable(
            track,
            quality,
            cancellation ?? PcmCancellation(),
            trace: trace,
          )
        : await resolver.resolve(track, quality);
    try {
      _checkActive(checkActive);
      cancellation?.check();
      final controlled = stream is ControlledOnlineStream;
      if (managed != null && !identical(_managed[id], managed)) {
        throw const OnlineException(OnlineErrorKind.closed);
      }
      if (stream.sourceId != id ||
          stream.requestedQuality != quality ||
          (controlled
              ? stream.uri.scheme != 'motif-controlled' ||
                    stream.owner.cancelled
              : managed != null ||
                    parsePlaybackUri(stream.uri.toString()) == null)) {
        throw const OnlineException(OnlineErrorKind.malformedResponse);
      }
      return stream;
    } catch (_) {
      if (stream is ControlledOnlineStream) stream.input.close();
      rethrow;
    }
  }

  void _checkActive(void Function()? check) {
    if (_closed) throw const OnlineException(OnlineErrorKind.closed);
    check?.call();
  }

  /// The application owns the shared QQ client; this registry owns its adapters.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final source in sources.skip(1)) {
      source.resolver.close();
    }
    _managed.clear();
  }
}

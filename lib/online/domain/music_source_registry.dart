import '../../audio/controlled_pcm.dart';
import 'online_error.dart';
import 'playback_source.dart';
import '../qq/qq_track.dart';

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
          (source) => source.id.isEmpty || source.name.trim().isEmpty,
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
  bool _closed = false;

  bool contains(String id) => sources.any((source) => source.id == id);

  String effectivePrimary(String id) => contains(id) ? id : 'qq';

  void registerManaged(MusicSourceRegistration source) {
    if (_closed ||
        source.id.isEmpty ||
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
    void Function()? checkActive,
    PcmCancellation? cancellation,
  }) async {
    _checkActive(checkActive);
    final ensureSources = loadManaged;
    if (ensureSources != null &&
        (preferredSourceId != 'qq' || fallbackSourceId != null)) {
      await ensureSources();
      _checkActive(checkActive);
    }
    final primary = effectivePrimary(preferredSourceId);
    final fallback =
        fallbackSourceId != primary &&
            fallbackSourceId != null &&
            contains(fallbackSourceId)
        ? fallbackSourceId
        : null;
    try {
      return await _resolve(primary, track, quality, checkActive, cancellation);
    } on OnlineException catch (error) {
      _checkActive(checkActive);
      // Account rejection and cooldowns must not become a fallback loop.
      if (fallback == null ||
          !{
            OnlineErrorKind.unavailable,
            OnlineErrorKind.unsupported,
            OnlineErrorKind.unsupportedFormat,
            OnlineErrorKind.unsupportedQuality,
            OnlineErrorKind.unsupportedRequest,
            OnlineErrorKind.transport,
          }.contains(error.kind)) {
        rethrow;
      }
      return _resolve(fallback, track, quality, checkActive, cancellation);
    }
  }

  Future<OnlineStream> _resolve(
    String id,
    QqTrack track,
    OnlineQuality quality,
    void Function()? checkActive,
    PcmCancellation? cancellation,
  ) async {
    _checkActive(checkActive);
    final managed = _managed[id];
    final source =
        managed ?? _builtIn.where((source) => source.id == id).firstOrNull;
    if (source == null) throw const OnlineException(OnlineErrorKind.closed);
    final resolver = source.resolver;
    final stream = resolver is CancellablePlaybackSource
        ? await resolver.resolveCancellable(
            track,
            quality,
            cancellation ?? PcmCancellation(),
          )
        : await resolver.resolve(track, quality);
    try {
      _checkActive(checkActive);
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

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
  }) : sources = List.unmodifiable([
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

  final List<MusicSourceRegistration> sources;
  bool _closed = false;

  bool contains(String id) => sources.any((source) => source.id == id);

  String effectivePrimary(String id) => contains(id) ? id : 'qq';

  Future<OnlineStream> resolve(
    QqTrack track,
    OnlineQuality quality, {
    String preferredSourceId = 'qq',
    String? fallbackSourceId,
    void Function()? checkActive,
  }) async {
    _checkActive(checkActive);
    final primary = effectivePrimary(preferredSourceId);
    final fallback =
        fallbackSourceId != primary &&
            fallbackSourceId != null &&
            contains(fallbackSourceId)
        ? fallbackSourceId
        : null;
    try {
      return await _resolve(primary, track, quality, checkActive: checkActive);
    } on OnlineException catch (error) {
      _checkActive(checkActive);
      // Account rejection and cooldowns must not become a fallback loop.
      if (fallback == null ||
          !{
            OnlineErrorKind.unavailable,
            OnlineErrorKind.unsupported,
            OnlineErrorKind.transport,
          }.contains(error.kind)) {
        rethrow;
      }
      return _resolve(fallback, track, quality, checkActive: checkActive);
    }
  }

  Future<OnlineStream> _resolve(
    String id,
    QqTrack track,
    OnlineQuality quality, {
    void Function()? checkActive,
  }) async {
    _checkActive(checkActive);
    final source = sources.singleWhere((source) => source.id == id);
    final stream = await source.resolver.resolve(track, quality);
    _checkActive(checkActive);
    if (stream.sourceId != id ||
        stream.requestedQuality != quality ||
        parsePlaybackUri(stream.uri.toString()) == null) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    return stream;
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
  }
}

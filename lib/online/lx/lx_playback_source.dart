import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../network/request_coordinator.dart';
import '../qq/qq_track.dart';
import 'lx_music_platform.dart';

/// Boundary for an isolated LX JavaScript host. This slice does not load or
/// execute scripts, or expose app credentials, filesystem or a network bridge.
abstract interface class LxScriptRuntime {
  Future<Object?> request(Map<String, Object?> event);

  /// Stop this request and its HTTP work before returning. A future host must
  /// not leave timed-out script work running while admitting another request.
  void cancelRequest();
}

class LxQqCapabilities {
  LxQqCapabilities._(this.qualities);
  final Set<OnlineQuality> qualities;

  /// Input is the payload of lx.send(lx.EVENT_NAMES.inited, payload).
  factory LxQqCapabilities.fromInit(Object? payload) {
    final tx = LxMusicCapabilities.fromInit(payload).byPlatform[LxPlatform.tx];
    if (tx == null) throw const OnlineException(OnlineErrorKind.unsupported);
    return LxQqCapabilities._(tx);
  }
}

/// QQ catalog identity stays QQ; LX uses its documented 'tx' source identifier.
/// Never searches or switches to another platform or script on a failed URL.
class LxPlaybackSource implements PlaybackUrlResolver {
  LxPlaybackSource({
    required this.sourceId,
    required this.runtime,
    required this.capabilities,
    RequestCoordinator? coordinator,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _coordinator = coordinator ?? RequestCoordinator() {
    if (sourceId.isEmpty || requestTimeout <= Duration.zero) {
      throw ArgumentError('Invalid LX source configuration');
    }
  }

  @override
  final String sourceId;
  final LxScriptRuntime runtime;
  final LxQqCapabilities capabilities;
  final Duration requestTimeout;
  final RequestCoordinator _coordinator;
  bool _requesting = false;

  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) {
    if (!capabilities.qualities.contains(quality)) {
      return Future.error(const OnlineException(OnlineErrorKind.unsupported));
    }
    if (track.mediaMid == null || track.mediaMid!.isEmpty) {
      return Future.error(const OnlineException(OnlineErrorKind.unavailable));
    }
    return _coordinator.run(
      '${track.mid}:${track.mediaMid}:${track.songType}:${quality.lxValue}',
      ttl: const Duration(seconds: 30),
      request: () async {
        Object? value;
        _requesting = true;
        try {
          value = await runtime
              .request({
                'source': 'tx',
                'action': 'musicUrl',
                'info': {
                  'type': quality.lxValue,
                  'musicInfo': lxQqMusicInfo(track),
                },
              })
              .timeout(
                requestTimeout,
                onTimeout: () {
                  _cancelRequest();
                  throw const OnlineException(OnlineErrorKind.transport);
                },
              );
        } finally {
          _requesting = false;
        }
        final uri = parsePlaybackUri(value);
        if (uri == null) {
          throw const OnlineException(OnlineErrorKind.malformedResponse);
        }
        return OnlineStream(
          uri: uri,
          sourceId: sourceId,
          requestedQuality: quality,
        );
      },
    );
  }

  void _cancelRequest() {
    if (!_requesting) return;
    _requesting = false;
    runtime.cancelRequest();
  }

  @override
  void close() {
    _coordinator.close();
    _cancelRequest();
  }
}

Map<String, Object?> lxQqMusicInfo(QqTrack track) {
  final types = [
    for (final quality in OnlineQuality.values)
      if (track.qualitySizes.containsKey(quality))
        {'type': quality.lxValue, 'size': lxSize(track.qualitySizes[quality]!)},
  ];
  final mappedTypes = {
    for (final item in types) item['type']!: {'size': item['size']},
  };
  final seconds = track.durationMs == null ? null : track.durationMs! ~/ 1000;
  final interval = seconds == null ? null : lxInterval(seconds);
  return {
    'source': 'tx',
    'songmid': track.mid,
    'songId': track.songId,
    'strMediaMid': track.mediaMid,
    'name': track.title,
    'singer': track.artists.join('、'),
    'albumName': track.album,
    'albumId': track.albumMid ?? '',
    'albumMid': track.albumMid ?? '',
    'interval': interval,
    'types': types,
    '_types': mappedTypes,
    'img': '',
    'typeUrl': <String, Object?>{},
  };
}

import '../domain/online_error.dart';
import '../domain/playback_source.dart';

/// Platforms for which the host can supply a genuine LX musicInfo. A script
/// declaration on its own does not give the host another platform's track ID.
enum LxPlatform {
  tx('QQ'),
  kw('酷我'),
  kg('酷狗');

  const LxPlatform(this.label);
  final String label;
}

final class LxMusicCapabilities {
  LxMusicCapabilities._(this.byPlatform);

  final Map<LxPlatform, Set<OnlineQuality>> byPlatform;
  late final Set<OnlineQuality> qualities = Set.unmodifiable(
    OnlineQuality.values.where(
      (q) => byPlatform.values.any((set) => set.contains(q)),
    ),
  );

  bool supports(LxPlatform platform, OnlineQuality quality) =>
      byPlatform[platform]?.contains(quality) ?? false;

  factory LxMusicCapabilities.fromInit(Object? payload) {
    if (payload is! Map || payload['sources'] is! Map) {
      throw const OnlineException(OnlineErrorKind.malformedResponse);
    }
    final sources = payload['sources'] as Map;
    final result = LxMusicCapabilities.fromStorage({
      for (final platform in LxPlatform.values)
        if (sources[platform.name]
            case {
              'type': 'music',
              'actions': List actions,
              'qualitys': List qualities,
            }
            when actions.contains('musicUrl'))
          platform.name: qualities,
    });
    if (result.byPlatform.isEmpty) {
      throw const OnlineException(OnlineErrorKind.unsupported);
    }
    return result;
  }

  factory LxMusicCapabilities.fromStorage(Map stored) {
    final channels = <LxPlatform, Set<OnlineQuality>>{};
    for (final platform in LxPlatform.values) {
      final raw = stored[platform.name];
      if (raw is! List) continue;
      final qualities = OnlineQuality.values.where(
        (q) => raw.contains(q.lxValue),
      );
      if (qualities.isNotEmpty) {
        channels[platform] = Set.unmodifiable(qualities);
      }
    }
    return LxMusicCapabilities._(Map.unmodifiable(channels));
  }

  Map<String, Object?> toJson() => {
    for (final entry in byPlatform.entries)
      entry.key.name: [for (final q in entry.value) q.lxValue],
  };
}

String lxInterval(int seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

String lxSize(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)}M'
    : '${(bytes / 1024).toStringAsFixed(2)}K';

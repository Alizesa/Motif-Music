import '../online/domain/playback_source.dart';

class OnlinePlaybackPreferences {
  const OnlinePlaybackPreferences({
    this.quality = OnlineQuality.standard,
    this.preferredSourceId = 'qq',
    this.fallbackSourceId,
  });

  final OnlineQuality quality;
  final String preferredSourceId;
  final String? fallbackSourceId;

  Map<String, Object?> toJson() => {
    'version': 1,
    'quality': quality.name,
    'preferredSourceId': preferredSourceId,
    'fallbackSourceId': fallbackSourceId,
  };

  factory OnlinePlaybackPreferences.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const FormatException('Invalid preferences');
    }
    final preferred = json['preferredSourceId'];
    final fallback = json['fallbackSourceId'];
    if (preferred is! String ||
        preferred.isEmpty ||
        preferred.length > 200 ||
        (fallback != null &&
            (fallback is! String ||
                fallback.isEmpty ||
                fallback.length > 200))) {
      throw const FormatException('Invalid source preferences');
    }
    final qualities = OnlineQuality.values.where(
      (quality) => quality.name == json['quality'],
    );
    if (qualities.length != 1) throw const FormatException('Invalid quality');
    return OnlinePlaybackPreferences(
      quality: qualities.single,
      preferredSourceId: preferred,
      fallbackSourceId: fallback == preferred ? null : fallback as String?,
    );
  }

  OnlinePlaybackPreferences copyWith({
    OnlineQuality? quality,
    String? preferredSourceId,
    String? fallbackSourceId,
    bool clearFallback = false,
  }) {
    final primary = preferredSourceId ?? this.preferredSourceId;
    final fallback = clearFallback
        ? null
        : fallbackSourceId ?? this.fallbackSourceId;
    return OnlinePlaybackPreferences(
      quality: quality ?? this.quality,
      preferredSourceId: primary,
      fallbackSourceId: fallback == primary ? null : fallback,
    );
  }
}

abstract interface class OnlinePlaybackPreferencesStore {
  Future<OnlinePlaybackPreferences> load();
  Future<void> save(OnlinePlaybackPreferences preferences);
}

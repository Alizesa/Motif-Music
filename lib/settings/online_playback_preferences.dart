import '../online/domain/playback_source.dart';
import '../online/lx/lx_ordered_source.dart' show lxOrderedSourceId;

class OnlinePlaybackPreferences {
  static const _maxBackups = 32;

  const OnlinePlaybackPreferences({
    this.quality = OnlineQuality.standard,
    this.preferredSourceId = 'qq',
    this.fallbackSourceId,
    this.scriptOrder = const [],
    this.fallbackOrder,
  });

  final OnlineQuality quality;
  final String preferredSourceId;
  final String? fallbackSourceId;
  final List<String> scriptOrder;

  /// Null until the user edits sources in the unified editor. Older versions
  /// could save a download order without opting into it for playback.
  final List<String>? fallbackOrder;

  String? get selectedPrimary => preferredSourceId == lxOrderedSourceId
      ? scriptOrder.firstOrNull
      : preferredSourceId;
  List<String> get selectedBackups =>
      fallbackOrder ??
      (preferredSourceId == lxOrderedSourceId
          ? scriptOrder.skip(1).toList()
          : [?fallbackSourceId]);

  // Download resolution only admits enabled LX scripts from these IDs. Legacy
  // download-only choices remain intact until a source edit, even after a quality edit.
  List<String> get downloadOrder => fallbackOrder == null
      ? scriptOrder
      : fallbackOrder!.isEmpty
      ? const []
      : [
          for (final id in [preferredSourceId, ...fallbackOrder!])
            if (id != 'qq') id,
        ];

  Map<String, Object?> toJson() => {
    'quality': quality.name,
    'preferredSourceId': preferredSourceId,
    if (fallbackOrder case final order?) ...{
      'version': 3,
      'fallbackOrder': order,
    } else ...{
      'version': 2,
      'scriptOrder': scriptOrder,
      'fallbackSourceId': fallbackSourceId,
    },
  };

  static bool _validId(Object? id) =>
      id is String && id.isNotEmpty && id.length <= 200;
  factory OnlinePlaybackPreferences.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (!const {1, 2, 3}.contains(version)) {
      throw const FormatException('Invalid preferences');
    }
    final unified = version == 3;
    final order = version == 1
        ? const []
        : json[unified ? 'fallbackOrder' : 'scriptOrder'];
    if (order is! List ||
        order.length > (unified ? _maxBackups : 12) ||
        order.any(
          (id) => !_validId(id) || (unified && id == lxOrderedSourceId),
        )) {
      throw const FormatException('Invalid source order');
    }
    final preferred = json['preferredSourceId'];
    final fallback = unified ? null : json['fallbackSourceId'];
    if (preferred is! String ||
        !_validId(preferred) ||
        (unified && preferred == lxOrderedSourceId) ||
        (fallback != null && !_validId(fallback))) {
      throw const FormatException('Invalid source preferences');
    }
    final qualities = OnlineQuality.values.where(
      (quality) => quality.name == json['quality'],
    );
    if (qualities.length != 1) throw const FormatException('Invalid quality');
    return OnlinePlaybackPreferences(
      quality: qualities.single,
      scriptOrder: unified
          ? const []
          : List.unmodifiable(order.cast<String>().toSet()),
      fallbackOrder: unified
          ? List.unmodifiable(order.cast<String>().toSet()..remove(preferred))
          : null,
      preferredSourceId: preferred,
      fallbackSourceId: fallback == preferred ? null : fallback as String?,
    );
  }

  OnlinePlaybackPreferences copyWith({
    OnlineQuality? quality,
    String? preferredSourceId,
    String? fallbackSourceId,
    bool clearFallback = false,
    List<String>? scriptOrder,
    List<String>? fallbackOrder,
  }) {
    final backups = fallbackOrder ?? this.fallbackOrder;
    if (backups != null) {
      final primary = preferredSourceId ?? selectedPrimary;
      if (primary == null ||
          !_validId(primary) ||
          primary == lxOrderedSourceId) {
        throw ArgumentError('Select a primary source first');
      }
      final order = clearFallback
          ? <String>{}
          : fallbackSourceId != null
          ? {fallbackSourceId}
          : backups.toSet();
      order.remove(primary);
      if (order.length > _maxBackups ||
          order.any((id) => !_validId(id) || id == lxOrderedSourceId)) {
        throw ArgumentError('Invalid backup source selection');
      }
      return OnlinePlaybackPreferences(
        quality: quality ?? this.quality,
        preferredSourceId: primary,
        fallbackOrder: List.unmodifiable(order),
      );
    }
    final primary = preferredSourceId ?? this.preferredSourceId;
    final fallback = clearFallback
        ? null
        : fallbackSourceId ?? this.fallbackSourceId;
    return OnlinePlaybackPreferences(
      quality: quality ?? this.quality,
      scriptOrder: List.unmodifiable((scriptOrder ?? this.scriptOrder).toSet()),
      preferredSourceId: primary,
      fallbackSourceId: fallback == primary ? null : fallback,
    );
  }
}

abstract interface class OnlinePlaybackPreferencesStore {
  Future<OnlinePlaybackPreferences> load();
  Future<void> save(OnlinePlaybackPreferences preferences);
}

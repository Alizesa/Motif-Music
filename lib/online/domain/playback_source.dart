import '../../audio/controlled_pcm.dart';
import '../../library/domain/audio_quality.dart';
import '../qq/qq_track.dart';

/// These are requested source tiers, not measurements of the returned audio.
enum OnlineQuality {
  standard('128k'),
  high('320k'),
  lossless('flac'),
  hiRes('flac24bit');

  const OnlineQuality(this.lxValue);
  final String lxValue;

  String get label => switch (this) {
    standard => '标准',
    high => '高音质',
    lossless => '无损',
    hiRes => 'Hi-Res',
  };
}

class OnlineStream {
  OnlineStream({
    required this.uri,
    required this.sourceId,
    required this.requestedQuality,
    this.reportedQuality,
  });

  final Uri uri;
  final String sourceId;
  final OnlineQuality requestedQuality;
  final AudioQuality? reportedQuality;
}

/// The URI is only a player identity. The external URL remains in the host's
/// transport. Revoking the source cancels the input and any active read.
final class ControlledOnlineStream extends OnlineStream {
  ControlledOnlineStream({
    required super.uri,
    required super.sourceId,
    required super.requestedQuality,
    required this.input,
    required this.owner,
  });

  final ControlledPcmInput input;
  final PcmCancellation owner;
}

abstract interface class PlaybackUrlResolver {
  String get sourceId;

  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality);

  void close();
}

abstract interface class CancellablePlaybackSource
    implements PlaybackUrlResolver {
  Future<OnlineStream> resolveCancellable(
    QqTrack track,
    OnlineQuality quality,
    PcmCancellation cancellation,
  );
}

Uri? parsePlaybackUri(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

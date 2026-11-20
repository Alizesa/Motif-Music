import 'dart:math' as math;

import 'package:mpv_audio_kit/mpv_audio_kit.dart';

import 'audio_engine.dart';

/// libmpv-backed audio engine used by the current cross-platform prototype.
/// Keep this adapter isolated so the native binding can be replaced if device
/// validation shows platform-specific limitations.
final class MpvAudioEngine implements AudioEngine {
  MpvAudioEngine()
    : _player = Player(
        configuration: const PlayerConfiguration(
          autoPlay: false,
          initialVolume: 75.0,
          resumePlayback: false,
        ),
      );

  final Player _player;
  final List<double> _equalizerGains = List<double>.filled(10, 0);
  double _preampDb = 0;

  @override
  Stream<bool> get playWhenReady => _player.stream.playWhenReady;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  late final Stream<AudioQueueSnapshot> _queue = _player.stream.playlist.map(
    (playlist) => AudioQueueSnapshot(
      tracks: playlist.items
          .map((media) {
            final title = media.extras?['title'];
            return AudioTrack(
              uri: media.uri,
              title: title is String && title.isNotEmpty ? title : media.uri,
            );
          })
          .toList(growable: false),
      currentIndex: playlist.index,
    ),
  );

  @override
  Stream<AudioQueueSnapshot> get queue => _queue;

  @override
  Stream<String> get errors => _player.stream.error.map((error) => '$error');

  @override
  Future<void> openQueue(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) return;

    // Do not silently accept invalid HTTPS certificates for online streams.
    await _player.setTlsVerify(true);
    // The queue stores lightweight references; do not decode the next track
    // while the current one is playing.
    await _player.setPrefetchPlaylist(false);
    await _player.setMediaSession(const MediaSession(appName: 'Motif'));

    final media = tracks
        .map((track) => Media(track.uri, extras: {'title': track.title}))
        .toList(growable: false);
    await _player.openAll(media, play: true);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<bool> next() => _player.next(force: false);

  @override
  Future<bool> previous() => _player.previous(force: false);

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double percent) => _player.setVolume(percent);

  @override
  Future<void> setEqualizer(List<double> gainsDb) async {
    if (gainsDb.length != equalizerCentersHz.length) {
      throw ArgumentError.value(
        gainsDb.length,
        'gainsDb.length',
        'Expected ${equalizerCentersHz.length} bands.',
      );
    }

    _equalizerGains.setAll(0, gainsDb);
    await _applyAudioEffects();
  }

  @override
  Future<void> setPreamp(double gainDb) async {
    if (gainDb < -12 || gainDb > 12) {
      throw RangeError.range(gainDb, -12, 12, 'gainDb');
    }
    _preampDb = gainDb;
    await _applyAudioEffects();
  }

  Future<void> _applyAudioEffects() async {
    final effects = <AudioEffect>[
      for (var index = 0; index < equalizerCentersHz.length; index++)
        EqualizerEffect(
          enabled: _equalizerGains[index].abs() > 0.001,
          frequency: equalizerCentersHz[index],
          gain: _equalizerGains[index],
          width: 1.0,
          widthType: EqualizerWidthType.o,
        ),
    ];

    if (_preampDb.abs() > 0.001) {
      final linearGain = math.pow(10, _preampDb / 20).toDouble();
      effects.insert(
        0,
        RawAudioEffect(
          'lavfi-volume=volume=${linearGain.toStringAsPrecision(7)}',
        ),
      );
    }
    await _player.setAudioEffects(effects);
  }

  @override
  Future<void> dispose() => _player.dispose();
}

/// Conventional octave-spaced test centers; product tuning is still open.
const equalizerCentersHz = <double>[
  31.0,
  63.0,
  125.0,
  250.0,
  500.0,
  1000.0,
  2000.0,
  4000.0,
  8000.0,
  16000.0,
];

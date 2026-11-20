import 'package:flutter/foundation.dart';

@immutable
class AudioTrack {
  const AudioTrack({required this.uri, required this.title});

  final String uri;
  final String title;
}

@immutable
class AudioQueueSnapshot {
  const AudioQueueSnapshot({required this.tracks, required this.currentIndex});

  static const empty = AudioQueueSnapshot(tracks: [], currentIndex: 0);

  final List<AudioTrack> tracks;
  final int currentIndex;

  AudioTrack? get currentTrack =>
      currentIndex >= 0 && currentIndex < tracks.length
      ? tracks[currentIndex]
      : null;
}

abstract interface class AudioEngine {
  Stream<bool> get playWhenReady;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<AudioQueueSnapshot> get queue;
  Stream<String> get errors;

  Future<void> openQueue(List<AudioTrack> tracks);
  Future<void> play();
  Future<void> pause();
  Future<bool> next();
  Future<bool> previous();
  Future<void> seek(Duration position);
  Future<void> setVolume(double percent);
  Future<void> setEqualizer(List<double> gainsDb);
  Future<void> setPreamp(double gainDb);
  Future<void> dispose();
}

import 'package:flutter/foundation.dart';

import 'controlled_pcm.dart';

@immutable
class AudioTrack {
  const AudioTrack({
    required this.uri,
    required this.title,
    this.artist,
    this.album,
  });

  final String uri;
  final String title;
  final String? artist;
  final String? album;
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
  Stream<bool> get completed;
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

enum AudioQueueNavigation { next, previous }

/// Optional bridge for native media keys when the application owns the queue.
abstract interface class ApplicationQueueAudioEngine {
  Stream<AudioQueueNavigation> get navigationRequests;
  void useApplicationQueueNavigation(bool enabled);
}

/// The internal identity survives replacement of the PCM segment on seek.
abstract interface class ControlledPcmAudioEngine {
  Future<void> openControlledPcm(
    ControlledPcmInput input, {
    required String title,
    String? artist,
    String? album,
    String? identity,
    PcmCancellation? cancellation,
    PcmCancellation? opening,
  });
}

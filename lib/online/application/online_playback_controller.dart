import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../audio/audio_engine.dart';
import '../../audio/controlled_pcm.dart';
import '../../library/domain/library_models.dart';
import '../../library/domain/library_playback_error.dart';
import '../../settings/online_playback_settings_controller.dart';
import '../domain/online_error.dart';
import '../domain/playback_source.dart';
import '../qq/qq_track.dart';
import 'recommendation_queue.dart';
import 'track_playback_resolver.dart';

/// One controller and engine survive page changes. A native playlist contains
/// only the current resolved item, so future URLs cannot expire in the queue.
class OnlinePlaybackController extends ChangeNotifier {
  OnlinePlaybackController({
    required this.engine,
    required this.resolver,
    required this.settings,
    required this.confirmLocal,
  }) {
    continuation = RecommendationContinuation(queue: queue, onChanged: _notify);
    _subscriptions.addAll([
      engine.playWhenReady.listen((value) {
        _playing = value;
        _notify();
      }),
      engine.position.listen((value) {
        _position = value;
        _notify();
      }),
      engine.duration.listen((value) {
        _duration = value;
        _notify();
      }),
      engine.queue.listen(_onNativeQueue),
      engine.completed.distinct().listen((value) {
        _completed = value;
        if (value && !_loading && _current != null && _error == null) {
          unawaited(next());
        }
      }),
      engine.errors.listen((_) {
        _error = '播放失败，请重试。';
        _notify();
      }),
    ]);
    if (engine case ApplicationQueueAudioEngine navigation) {
      navigation.useApplicationQueueNavigation(true);
      _subscriptions.add(
        navigation.navigationRequests.listen((command) {
          if (command == AudioQueueNavigation.next) {
            unawaited(next());
          } else {
            unawaited(previous());
          }
        }),
      );
    }
  }

  final AudioEngine engine;
  final TrackPlaybackResolver resolver;
  final OnlinePlaybackSettingsController settings;
  final ConfirmLocalPlayback confirmLocal;
  final RecommendationQueue queue = RecommendationQueue();
  late final RecommendationContinuation continuation;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _engineTail = Future.value();
  Future<bool> Function()? _retry;
  QqTrack? _current;
  QqTrack? _requested;
  AudioTrack? _external;
  String? _currentUri;
  PcmCancellation? _intent;
  void Function()? _watchControlled;
  AudioQueueSnapshot _nativeQueue = AudioQueueSnapshot.empty;
  bool _closed = false;
  bool _loading = false;
  bool _playing = false;
  bool _completed = false;
  int _generation = 0;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  QqTrack? get currentTrack => _current;
  String? get currentTitle =>
      _current?.title ??
      _external?.title ??
      (_loading ? _requested?.title : null);
  String get currentArtist =>
      _current?.artists.join('、') ??
      (_external == null && _loading ? _requested?.artists.join('、') : null) ??
      '';
  bool get isLoading => _loading;
  bool get isPlaying => _playing;
  bool get hasMedia => currentTitle != null || queue.tracks.isNotEmpty;
  String? get error => _error;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get canNext => _current != null
      ? queue.currentIndex + 1 < queue.tracks.length || continuation.isActive
      : queue.tracks.isNotEmpty ||
            _nativeQueue.currentIndex + 1 < _nativeQueue.tracks.length;
  bool get canPrevious =>
      _current != null ? queue.currentIndex > 0 : _nativeQueue.currentIndex > 0;

  Future<bool> playQueue(
    List<QqTrack> tracks, {
    int startIndex = 0,
    Future<List<QqTrack>> Function()? nextRecommendationBatch,
  }) async {
    final draft = RecommendationQueue();
    try {
      draft.replace(tracks, startIndex: startIndex);
    } catch (error) {
      _report(error);
      return false;
    }
    continuation.stop();
    _retry = () => playQueue(
      draft.tracks,
      startIndex: draft.currentIndex,
      nextRecommendationBatch: nextRecommendationBatch,
    );
    return _load(draft.tracks[draft.currentIndex], () {
      queue.replace(draft.tracks, startIndex: draft.currentIndex);
      if (nextRecommendationBatch != null) {
        continuation.begin(nextRecommendationBatch);
      }
    });
  }

  Future<bool> select(int index) {
    if (index < 0 || index >= queue.tracks.length || _closed) {
      return Future.value(false);
    }
    final track = queue.tracks[index];
    _retry = () => select(
      queue.tracks.indexWhere((item) => item.identity == track.identity),
    );
    return _load(track, () => queue.select(index));
  }

  Future<bool> _load(QqTrack track, void Function() commitQueue) async {
    if (_closed) return false;
    final generation = ++_generation;
    _intent?.cancel();
    final intent = _intent = PcmCancellation();
    bool isCurrent() => !_closed && generation == _generation;
    _loading = true;
    _requested = track;
    _error = null;
    _notify();
    ControlledOnlineStream? managed;
    var ownedByEngine = false;
    try {
      await settings.initialize();
      if (!isCurrent()) return false;
      if (!settings.isReady) throw StateError('Preferences unavailable');
      final preferences = settings.value;
      final resolved = await resolver.resolve(
        track,
        preferences.quality,
        preferredSourceId: preferences.preferredSourceId,
        fallbackSourceId: preferences.fallbackSourceId,
        confirm: confirmLocal,
        isCurrent: isCurrent,
        cancellation: intent,
      );
      if (resolved.stream case ControlledOnlineStream stream) managed = stream;
      if (!isCurrent()) return false;
      await _serializeEngine(() async {
        if (!isCurrent()) return;
        if (managed case final stream?) {
          final player = engine;
          if (player is! ControlledPcmAudioEngine) {
            throw const OnlineException(OnlineErrorKind.unsupported);
          }
          final controlled = player as ControlledPcmAudioEngine;
          stream.owner.check();
          ownedByEngine = true;
          await controlled.openControlledPcm(
            stream.input,
            title: track.title,
            artist: track.artists.join('、'),
            album: track.album,
            identity: resolved.uri,
            cancellation: stream.owner,
            opening: intent,
          );
          stream.owner.check();
        } else {
          await engine.openQueue([
            AudioTrack(
              uri: resolved.uri,
              title: track.title,
              artist: track.artists.join('、'),
              album: track.album,
            ),
          ]);
        }
        if (!isCurrent()) return;
        _stopWatchingControlled();
        commitQueue();
        _current = track;
        _external = null;
        _currentUri = resolved.uri;
        if (managed case final stream?) {
          _watchControlled = stream.owner.listen(() {
            if (_currentUri != resolved.uri || _closed) return;
            _completed = true;
            _playing = false;
            _notify();
          });
        }
        _position = Duration.zero;
        _completed = false;
      });
      if (!isCurrent()) return false;
      unawaited(continuation.check());
      return true;
    } on PlaybackCancelled {
      return false;
    } on PcmCancelled {
      return false;
    } catch (error) {
      if (isCurrent()) _report(error);
      return false;
    } finally {
      if (!ownedByEngine) managed?.input.close();
      if (identical(_intent, intent)) _intent = null;
      if (isCurrent()) {
        _loading = false;
        _requested = null;
        _notify();
      }
    }
  }

  /// The library route has already verified this file using playFile.
  Future<void> playLocal(LocalAudioFile file) async {
    if (_closed) throw const PlaybackCancelled();
    final generation = ++_generation;
    _intent?.cancel();
    continuation.stop();
    _loading = true;
    _error = null;
    _notify();
    try {
      await _serializeEngine(() async {
        if (_closed || generation != _generation) {
          throw const PlaybackCancelled();
        }
        final track = AudioTrack(
          uri: file.location.locator,
          title: file.displayTitle,
          artist: file.metadata.artist.isEmpty ? null : file.metadata.artist,
          album: file.metadata.album.isEmpty ? null : file.metadata.album,
        );
        await engine.openQueue([track]);
        if (_closed || generation != _generation) {
          throw const PlaybackCancelled();
        }
        queue.clear();
        _stopWatchingControlled();
        _current = null;
        _external = track;
        _currentUri = track.uri;
        _position = Duration.zero;
      });
    } finally {
      if (!_closed && generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  int append(List<QqTrack> tracks) {
    if (_closed || tracks.isEmpty) return 0;
    final count = tracks.length.clamp(0, queue.maxTracks);
    final bounded = tracks.take(count).toList();
    final int added;
    if (queue.tracks.isEmpty) {
      queue.replace(bounded);
      added = queue.tracks.length;
    } else {
      added = queue.append(bounded);
    }
    _notify();
    return added;
  }

  void releaseCatalogQueue() {
    if (_closed) return;
    _generation++;
    _intent?.cancel();
    _stopWatchingControlled();
    continuation.stop();
    queue.clear();
    if (_current != null && _currentUri != null) {
      _external = AudioTrack(uri: _currentUri!, title: _current!.title);
    }
    _current = null;
    _requested = null;
    _loading = false;
    _retry = null;
    _error = null;
    _notify();
  }

  Future<bool> next() async {
    if (_closed || _loading) return false;
    final generation = _generation;
    if (_current == null && queue.tracks.isNotEmpty) return select(0);
    if (_current != null) {
      if (queue.currentIndex + 1 >= queue.tracks.length) {
        await continuation.check();
        if (_closed || _loading || generation != _generation) return false;
      }
      if (queue.currentIndex + 1 < queue.tracks.length) {
        return select(queue.currentIndex + 1);
      }
      return false;
    }
    try {
      var moved = false;
      await _serializeEngine(() async {
        if (!_closed && generation == _generation) moved = await engine.next();
      });
      return moved;
    } catch (error) {
      _report(error);
      return false;
    }
  }

  Future<bool> previous() async {
    if (_closed || _loading) return false;
    if (_current != null) {
      return queue.currentIndex > 0 ? select(queue.currentIndex - 1) : false;
    }
    try {
      var moved = false;
      final generation = _generation;
      await _serializeEngine(() async {
        if (!_closed && generation == _generation) {
          moved = await engine.previous();
        }
      });
      return moved;
    } catch (error) {
      _report(error);
      return false;
    }
  }

  Future<void> togglePlay() async {
    if (_closed || _loading) return;
    if (_current != null && _completed) {
      await select(queue.currentIndex);
      return;
    }
    if (currentTitle == null && queue.tracks.isNotEmpty) {
      await select(0);
      return;
    }
    try {
      final generation = _generation;
      final pause = _playing;
      await _serializeEngine(() async {
        if (!_closed && generation == _generation) {
          await (pause ? engine.pause() : engine.play());
        }
      });
    } catch (error) {
      _report(error);
    }
  }

  Future<void> seek(Duration target) async {
    if (_closed || _loading) return;
    try {
      final generation = _generation;
      await _serializeEngine(() async {
        if (!_closed && generation == _generation) await engine.seek(target);
      });
    } catch (error) {
      _report(error);
    }
  }

  Future<bool> retry() => _retry?.call() ?? Future.value(false);

  Future<void> _serializeEngine(Future<void> Function() action) {
    final result = _engineTail.then((_) => action());
    _engineTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _onNativeQueue(AudioQueueSnapshot snapshot) {
    if (_closed) return;
    _nativeQueue = snapshot;
    if (!_loading && snapshot.currentTrack?.uri != _currentUri) {
      _generation++;
      _intent?.cancel();
      _stopWatchingControlled();
      continuation.stop();
      queue.clear();
      _current = null;
      _external = snapshot.currentTrack;
      _currentUri = snapshot.currentTrack?.uri;
    }
    _notify();
  }

  void _stopWatchingControlled() {
    _watchControlled?.call();
    _watchControlled = null;
  }

  void _report(Object error) {
    if (_closed) return;
    _error = switch (error) {
      OnlineException value => value.toString(),
      LibraryPlaybackException value => value.toString(),
      _ => '播放失败，请重试。',
    };
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    if (engine case ApplicationQueueAudioEngine navigation) {
      navigation.useApplicationQueueNavigation(false);
    }
    _generation++;
    _intent?.cancel();
    _stopWatchingControlled();
    continuation.stop();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

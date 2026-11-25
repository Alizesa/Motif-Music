import 'dart:async';

import 'package:mpv_audio_kit/mpv_audio_kit.dart';

import 'audio_engine.dart';
import 'controlled_pcm.dart';

/// libmpv-backed audio engine used by the current cross-platform prototype.
/// Keep this adapter isolated so the native binding can be replaced if device
/// validation shows platform-specific limitations.
final class MpvAudioEngine
    implements
        AudioEngine,
        ApplicationQueueAudioEngine,
        ControlledPcmAudioEngine {
  MpvAudioEngine({PlayerApi? player})
    : _player =
          player ??
          Player(
            configuration: const PlayerConfiguration(
              autoPlay: false,
              initialVolume: 75.0,
              resumePlayback: false,
            ),
          );

  final PlayerApi _player;
  final List<double> _equalizerGains = List<double>.filled(10, 0);
  final _controlledErrors = StreamController<String>.broadcast();
  final _mediaChange = StreamController<void>.broadcast();
  Future<void> _mediaWrites = Future.value();
  Future<void>? _closing;
  PcmCancellation? _pending;
  PcmCancellation? _controlledPending;
  _ControlledTrack? _controlled;
  (_ControlledTrack, PcmCancellation)? _switchingSegment;
  bool _disposed = false;
  bool _applicationNavigation = false;

  @override
  Stream<bool> get playWhenReady => _player.stream.playWhenReady;

  late final _position = _withControlled(_player.stream.position, (position) {
    final track = _controlled;
    if (track == null) return position;
    if (track.finished) return track.duration;
    if (track.segment?.media.uri != _player.state.file.path) {
      return track.offset;
    }
    final actual = track.offset + position;
    return actual > track.duration ? track.duration : actual;
  });
  @override
  Stream<Duration> get position => _position;

  late final _duration = _withControlled(
    _player.stream.duration,
    (value) => _controlled?.duration ?? value,
  );
  @override
  Stream<Duration> get duration => _duration;

  Stream<Duration> _withControlled(
    Stream<Duration> native,
    Duration Function(Duration) transform,
  ) => Stream.multi((events) {
    var last = Duration.zero;
    final observed = native.listen((value) {
      last = value;
      events.add(transform(last));
    });
    final changed = _mediaChange.stream.listen(
      (_) => events.add(transform(last)),
      onDone: events.close,
    );
    events.onCancel = () async {
      await observed.cancel();
      await changed.cancel();
    };
  }, isBroadcast: true);

  @override
  Stream<bool> get completed => _player.stream.completed.where(
    (value) => !value || !_switchingControlledSegment,
  );

  bool get _switchingControlledSegment =>
      _controlled != null && identical(_controlled, _switchingSegment?.$1);

  @override
  Stream<AudioQueueNavigation> get navigationRequests => _player
      .stream
      .mediaSessionCommands
      .where(
        (command) =>
            command is MediaSessionCommandNext ||
            command is MediaSessionCommandPrevious,
      )
      .map(
        (command) => command is MediaSessionCommandNext
            ? AudioQueueNavigation.next
            : AudioQueueNavigation.previous,
      );

  @override
  void useApplicationQueueNavigation(bool enabled) {
    _applicationNavigation = enabled;
  }

  late final Stream<AudioQueueSnapshot> _queue = _player.stream.playlist
      .where(
        (playlist) => playlist.items.isNotEmpty || !_switchingControlledSegment,
      )
      .map(
        (playlist) => AudioQueueSnapshot(
          tracks: playlist.items
              .map((media) {
                final title = media.extras?['title'];
                final artist = media.extras?['artist'];
                final album = media.extras?['album'];
                final identity = media.extras?['motifPcmIdentity'];
                return AudioTrack(
                  uri: identity is String ? identity : media.uri,
                  title: title is String && title.isNotEmpty
                      ? title
                      : media.uri,
                  artist: artist is String ? artist : null,
                  album: album is String ? album : null,
                );
              })
              .toList(growable: false),
          currentIndex: playlist.index,
        ),
      );

  @override
  Stream<AudioQueueSnapshot> get queue => _queue;

  @override
  Stream<String> get errors => Stream.multi((events) {
    final native = _player.stream.error.listen(
      (error) => events.add(_controlled == null ? '$error' : '受控音频播放失败。'),
    );
    final controlled = _controlledErrors.stream.listen(
      events.add,
      onDone: events.close,
    );
    events.onCancel = () async {
      await native.cancel();
      await controlled.cancel();
    };
  }, isBroadcast: true);

  @override
  Future<void> openQueue(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) return;
    if (_disposed ||
        tracks.any(
          (track) => track.uri.trimLeft().toLowerCase().startsWith('mak-pcm:'),
        )) {
      throw StateError('Audio source unavailable');
    }
    final pending = _begin();
    final retired = _takeControlled();
    try {
      await _serializeMedia(() async {
        // Stop the old PCM entry before the new load. PcmSource.abort()
        // can request playlist-next on the native player.
        await _stopRetired(retired);
        pending.check();
        await _preparePlayer();
        pending.check();
        final media = tracks
            .map(
              (track) => Media(
                track.uri,
                extras: {
                  'title': track.title,
                  if (track.artist != null) 'artist': track.artist,
                  if (track.album != null) 'album': track.album,
                },
              ),
            )
            .toList(growable: false);
        await _player.openAll(media, play: true);
      });
    } finally {
      _done(pending);
    }
  }

  Future<void> _preparePlayer() async {
    // Do not silently accept invalid HTTPS certificates for online streams.
    await _player.setTlsVerify(true);
    // The queue stores lightweight references; do not decode the next track
    // while the current one is playing.
    await _player.setPrefetchPlaylist(false);
    await _player.setMediaSession(
      MediaSession(
        appName: 'Motif',
        autoApplyPlaylistNavigation: !_applicationNavigation,
      ),
    );
  }

  /// Takes ownership of one checked input. Only PCM samples enter libmpv.
  @override
  Future<void> openControlledPcm(
    ControlledPcmInput input, {
    required String title,
    String? artist,
    String? album,
    String? identity,
    PcmCancellation? cancellation,
    PcmCancellation? opening,
  }) async {
    if (_disposed) {
      input.close();
      throw const PcmCancelled();
    }
    final track = _ControlledTrack(input, {
      'title': title,
      'artist': ?artist,
      'album': ?album,
      'motifPcmIdentity': ?identity,
    });
    final unlinkOpening = opening?.listen(track.cancellation.cancel);
    track.listenToOwner(cancellation, () {
      if (!identical(_controlled, track)) {
        track.closeInput();
        return;
      }
      final retired = _takeControlled();
      unawaited(
        _serializeMedia(() => _stopRetired(retired)).catchError((Object _) {}),
      );
    });
    try {
      if ((input.channels != 1 && input.channels != 2) ||
          input.sampleRate < 8000 ||
          input.sampleRate > 192000 ||
          input.frames < 1 ||
          input.frames > 128 * 1024 * 1024) {
        throw ArgumentError('Unsupported controlled PCM layout');
      }
      await _openSegment(track, 0, replace: true);
    } catch (_) {
      track.closeInput();
      rethrow;
    } finally {
      unlinkOpening?.call();
    }
  }

  PcmCancellation _begin() {
    _pending?.cancel();
    return _pending = PcmCancellation();
  }

  void _done(PcmCancellation operation) {
    if (identical(_pending, operation)) _pending = null;
  }

  Future<void> _serializeMedia(Future<void> Function() action) {
    final result = _mediaWrites.then((_) => action());
    _mediaWrites = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _openSegment(
    _ControlledTrack track,
    int frame, {
    required bool replace,
  }) async {
    final operation = _begin();
    _controlledPending = operation;
    final unlisten = track.cancellation.listen(operation.cancel);
    ControlledPcmRead? reader;
    _PcmSegment? segment;
    var committed = false;
    var sentToPlayer = false;
    try {
      operation.check();
      final candidate = await operation.until<ControlledPcmRead>(
        track.input.openAt(frame, operation),
        discard: (late) => late.close(),
      );
      reader = candidate;
      final start = await operation.until(
        candidate.read(_PcmSegment.chunkBytes),
      );
      if (start.isEmpty || start.length > _PcmSegment.chunkBytes) {
        throw StateError('Controlled PCM input is empty');
      }
      await _serializeMedia(() async {
        operation.check();
        if (_disposed || (!replace && !identical(track, _controlled))) {
          throw const PcmCancelled();
        }
        await _preparePlayer();
        operation.check();
        final play = replace || _player.state.playback.playWhenReady;
        final old = _controlled;
        if (old != null) {
          final previous = old.segment;
          if (identical(old, track)) {
            _switchingSegment = (track, operation);
            previous?.closeInput();
          } else {
            _takeControlled();
          }
          try {
            await _player.stop();
          } finally {
            previous?.source.abort();
          }
          operation.check();
        }
        final sink = PcmSource.create(
          PcmFormat(
            sampleRate: track.input.sampleRate,
            channels: track.input.channels,
          ),
          maxBuffered: const Duration(seconds: 1),
        );
        final next = segment = _PcmSegment(
          sink,
          candidate,
          operation,
          sink.toMedia(extras: track.extras),
        );
        _controlled = track;
        track.segment = next;
        track.offset = track.durationAt(frame);
        track.finished = false;
        next.source.add(start);
        _mediaChange.add(null);
        try {
          sentToPlayer = true;
          await _player.open(next.media, play: play);
          operation.check();
        } catch (_) {
          next.closeInput();
          if (identical(_controlled, track) && identical(track.segment, next)) {
            await _stopRetired(_takeControlled());
          }
          rethrow;
        }
        committed = true;
        unawaited(_feed(track, next));
      });
    } finally {
      if (identical(_switchingSegment?.$2, operation)) _switchingSegment = null;
      unlisten();
      _done(operation);
      if (identical(_controlledPending, operation)) _controlledPending = null;
      if (!committed) {
        operation.cancel();
        if (segment case final unattached?) {
          unattached.closeInput();
          if (!sentToPlayer) unattached.source.abort();
        }
        reader?.close();
        if (segment != null &&
            identical(_controlled, track) &&
            identical(track.segment, segment)) {
          _takeControlled();
        }
      }
    }
  }

  Future<void> _feed(_ControlledTrack track, _PcmSegment segment) async {
    final input = segment.reader;
    final output = segment.source;
    final operation = segment.cancellation;
    var reachedEnd = false;
    unawaited(
      output.done.then((_) {
        if (!reachedEnd) operation.cancel();
      }),
    );
    try {
      while (!output.isDone) {
        await operation.until(output.ready);
        operation.check();
        final chunk = await operation.until(input.read(_PcmSegment.chunkBytes));
        operation.check();
        if (chunk.isEmpty) {
          reachedEnd = true;
          await operation.until(output.close());
          break;
        }
        if (chunk.length > _PcmSegment.chunkBytes) {
          throw StateError('Controlled PCM read exceeded its limit');
        }
        output.add(chunk);
      }
      if (reachedEnd &&
          identical(_controlled, track) &&
          identical(track.segment, segment) &&
          !operation.cancelled) {
        // The response is already closed; retain the checked input for seek
        // until native playback of its buffered samples actually completes.
        segment.watchEnd(
          _player.stream.completed
              .where(
                (complete) =>
                    complete && _player.state.file.path == segment.media.uri,
              )
              .listen((_) {
                if (identical(_controlled, track) &&
                    identical(track.segment, segment)) {
                  track.finished = true;
                  track.input.close();
                  _mediaChange.add(null);
                }
              }),
        );
      }
    } on PcmCancelled {
      // A successor or a revoke owns native teardown.
    } catch (_) {
      if (identical(_controlled, track) && identical(track.segment, segment)) {
        _controlledErrors.add('受控音频读取失败。');
        final retired = _takeControlled();
        try {
          await _serializeMedia(() => _stopRetired(retired));
        } catch (_) {
          // The read failure has already been reported.
        }
      }
    } finally {
      input.close();
    }
  }

  _ControlledTrack? _takeControlled() {
    final old = _controlled;
    _controlled = null;
    old?.closeInput();
    if (old != null) _mediaChange.add(null);
    return old;
  }

  Future<void> _stopRetired(_ControlledTrack? retired) async {
    if (retired == null) return;
    try {
      await _player.stop();
    } finally {
      retired.segment?.source.abort();
    }
  }

  Future<void> closeControlledPcm() async {
    if (_disposed) return;
    // This entry is also used to revoke a staged opening before it obtains a
    // native source. Only an existing controlled track calls player.stop().
    _controlledPending?.cancel();
    final active = _takeControlled();
    if (active != null) await _serializeMedia(() => _stopRetired(active));
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
  Future<void> seek(Duration position) async {
    final track = _controlled;
    if (_disposed) throw const PcmCancelled();
    if (track == null) return _player.seek(position);
    if (!track.input.seekable || track.finished) {
      throw StateError('当前测试音频无法跳转，请重新播放。');
    }
    final frame =
        (position.inMicroseconds *
                track.input.sampleRate ~/
                Duration.microsecondsPerSecond)
            .clamp(0, track.input.frames - 1);
    await _openSegment(track, frame, replace: false);
  }

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
    if (!gainDb.isFinite || gainDb < -12 || gainDb > 12) {
      throw RangeError.range(gainDb, -12, 12, 'gainDb');
    }
    // Native dB gain stays independent of the EQ filter chain.
    await _player.setVolumeGain(gainDb);
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

    await _player.setAudioEffects(effects);
  }

  @override
  Future<void> dispose() => _closing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _pending?.cancel();
    final active = _takeControlled();
    try {
      await _serializeMedia(() async {
        await _player.dispose();
        active?.segment?.source.abort();
      });
    } finally {
      await _controlledErrors.close();
      await _mediaChange.close();
    }
  }
}

final class _ControlledTrack {
  _ControlledTrack(this.input, this.extras);

  final ControlledPcmInput input;
  final Map<String, String> extras;
  final cancellation = PcmCancellation();
  void Function()? _removeOwner;
  _PcmSegment? segment;
  Duration offset = Duration.zero;
  bool finished = false;

  Duration durationAt(int frame) => Duration(
    microseconds: frame * Duration.microsecondsPerSecond ~/ input.sampleRate,
  );
  Duration get duration => durationAt(input.frames);

  void listenToOwner(PcmCancellation? owner, void Function() onCancel) {
    _removeOwner = owner?.listen(onCancel);
  }

  void closeInput() {
    _removeOwner?.call();
    _removeOwner = null;
    cancellation.cancel();
    segment?.closeInput();
    input.close();
  }
}

final class _PcmSegment {
  _PcmSegment(this.source, this.reader, this.cancellation, this.media);
  static const chunkBytes = 32 * 1024;
  final PcmSource source;
  final ControlledPcmRead reader;
  final PcmCancellation cancellation;
  final Media media;
  StreamSubscription<bool>? _end;
  bool _closed = false;

  void watchEnd(StreamSubscription<bool> value) => _end = value;
  void closeInput() {
    if (_closed) return;
    _closed = true;
    unawaited(_end?.cancel());
    cancellation.cancel();
    reader.close();
  }
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

import 'dart:async';
import 'dart:io';

import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/library_playback_error.dart';
import 'package:motif/library/domain/local_playback_matcher.dart';
import 'package:motif/online/application/recommendation_queue.dart';
import 'package:motif/online/application/track_playback_resolver.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_playback_source.dart';
import 'package:motif/online/qq/qq_track.dart';
import 'package:motif/settings/file_online_playback_preferences_store.dart';
import 'package:motif/settings/online_playback_preferences.dart';
import 'package:motif/settings/playback_quality_settings.dart';

import 'online_fakes.dart';
import 'playback_fakes.dart';

/// Shared by the CI test wrapper and a plain Dart console entrypoint. These
/// checks import no Flutter UI, native library, substituted hook or asset map.
Map<String, Future<void> Function()> playbackContractChecks() => {
  'QQ catalog identities include the song type': () async {
    final first = playbackTrack(1);
    final other = QqTrack(
      mid: first.mid,
      songType: 1,
      title: first.title,
      artists: first.artists,
      album: first.album,
    );
    _check(first.identity != other.identity, 'Distinct song types were merged');
  },
  'registry rejects duplicate source identities': () async {
    final qq = FakePlaybackSource('qq');
    await _throws<ArgumentError>(
      () async => MusicSourceRegistry(
        qq: qq,
        thirdPartySources: [
          MusicSourceRegistration(name: 'Duplicate', resolver: qq),
        ],
      ),
    );
  },
  'preferred third-party resolution preserves QQ identity and tier': () async {
    final qq = FakePlaybackSource('qq');
    final third = FakePlaybackSource('custom');
    final registry = _registry(qq, third);
    final track = playbackTrack(1);
    final result = await registry.resolve(
      track,
      OnlineQuality.high,
      preferredSourceId: 'custom',
      fallbackSourceId: 'qq',
    );
    _check(result.sourceId == 'custom', 'Wrong primary source');
    _check(
      qq.calls.isEmpty && third.calls.length == 1,
      'Unexpected source call',
    );
    _check(identical(third.calls.single.$1, track), 'Catalog identity changed');
    _check(third.calls.single.$2 == OnlineQuality.high, 'Quality changed');
  },
  'one configured fallback handles an unavailable primary': () async {
    final qq = FakePlaybackSource('qq');
    final third = FakePlaybackSource('custom')
      ..reply = (_, _) async =>
          throw const OnlineException(OnlineErrorKind.unavailable);
    final result = await _registry(qq, third).resolve(
      playbackTrack(1),
      OnlineQuality.standard,
      preferredSourceId: 'custom',
      fallbackSourceId: 'qq',
    );
    _check(result.sourceId == 'qq', 'Fallback was not used');
    _check(qq.calls.length == 1 && third.calls.length == 1, 'Fallback loop');
  },
  'cancelling a primary request prevents its later fallback': () async {
    final qq = FakePlaybackSource('qq');
    final pending = Completer<OnlineStream>();
    final third = FakePlaybackSource('custom')
      ..reply = (_, _) => pending.future;
    var active = true;
    final result = _throws<PlaybackCancelled>(
      () => _registry(qq, third).resolve(
        playbackTrack(1),
        OnlineQuality.standard,
        preferredSourceId: 'custom',
        fallbackSourceId: 'qq',
        checkActive: () {
          if (!active) throw const PlaybackCancelled();
        },
      ),
    );
    active = false;
    pending.completeError(const OnlineException(OnlineErrorKind.unavailable));
    await result;
    _check(qq.calls.isEmpty, 'Cancelled primary started a fallback');
  },
  'closing a registry prevents a failed primary from starting fallback':
      () async {
        final qq = FakePlaybackSource('qq');
        final pending = Completer<OnlineStream>();
        final third = FakePlaybackSource('custom')
          ..reply = (_, _) => pending.future;
        final registry = _registry(qq, third);
        final result = _throws<OnlineException>(
          () => registry.resolve(
            playbackTrack(1),
            OnlineQuality.standard,
            preferredSourceId: 'custom',
            fallbackSourceId: 'qq',
          ),
        );
        registry.close();
        pending.completeError(
          const OnlineException(OnlineErrorKind.unavailable),
        );
        final error = await result;
        _check(
          error.kind == OnlineErrorKind.closed && qq.calls.isEmpty,
          'Closed primary started fallback',
        );
      },
  for (final kind in [
    OnlineErrorKind.rateLimited,
    OnlineErrorKind.rejected,
    OnlineErrorKind.closed,
  ])
    'fallback stops on ${kind.name}': () async {
      final qq = FakePlaybackSource('qq');
      final third = FakePlaybackSource('custom')
        ..reply = (_, _) async => throw OnlineException(kind);
      final error = await _throws<OnlineException>(
        () => _registry(qq, third).resolve(
          playbackTrack(1),
          OnlineQuality.standard,
          preferredSourceId: 'custom',
          fallbackSourceId: 'qq',
        ),
      );
      _check(
        error.kind == kind && qq.calls.isEmpty,
        'Protected failure fell back',
      );
    },
  'registry rejects a mismatched returned quality': () async {
    final qq = FakePlaybackSource('qq')
      ..reply = (_, _) async => OnlineStream(
        uri: Uri.https('audio.example', '/song.mp3'),
        sourceId: 'qq',
        requestedQuality: OnlineQuality.lossless,
      );
    final error = await _throws<OnlineException>(
      () =>
          MusicSourceRegistry(qq: qq)
              .resolve(playbackTrack(1), OnlineQuality.standard),
    );
    _check(
      error.kind == OnlineErrorKind.malformedResponse,
      'Wrong tier was accepted',
    );
  },
  'unique verified local playback makes no online request': () async {
    final qq = FakePlaybackSource('qq');
    final file = playbackFile(1);
    var prepared = 0;
    final resolver = TrackPlaybackResolver(
      sources: MusicSourceRegistry(qq: qq),
      matchLocal: (_, _) async => _local(file),
      prepareLocal: (value) async {
        prepared++;
        return value;
      },
    );
    final result = await resolver.resolve(
      playbackTrack(1),
      OnlineQuality.standard,
      confirm: (_, _) async => throw StateError('Unexpected confirmation'),
      isCurrent: () => true,
    );
    _check(
      result.localFile == file && prepared == 1,
      'Local access was not checked',
    );
    _check(qq.calls.isEmpty, 'Local match fetched an online URL');
  },
  'lost local access falls back to the configured online source': () async {
    final qq = FakePlaybackSource('qq');
    final resolver = TrackPlaybackResolver(
      sources: MusicSourceRegistry(qq: qq),
      matchLocal: (_, _) async => _local(playbackFile(1)),
      prepareLocal: (_) async => throw const LibraryPlaybackException(
        LibraryPlaybackErrorKind.unavailable,
      ),
    );
    final result = await resolver.resolve(
      playbackTrack(1),
      OnlineQuality.standard,
      confirm: (_, _) async => null,
      isCurrent: () => true,
    );
    _check(
      result.localFile == null && qq.calls.length == 1,
      'Lost file did not fall back',
    );
  },
  'busy local access does not masquerade as a missing match': () async {
    final qq = FakePlaybackSource('qq');
    final resolver = TrackPlaybackResolver(
      sources: MusicSourceRegistry(qq: qq),
      matchLocal: (_, _) async => _local(playbackFile(1)),
      prepareLocal: (_) async =>
          throw const LibraryPlaybackException(LibraryPlaybackErrorKind.busy),
    );
    await _throws<LibraryPlaybackException>(
      () => resolver.resolve(
        playbackTrack(1),
        OnlineQuality.standard,
        confirm: (_, _) async => null,
        isCurrent: () => true,
      ),
    );
    _check(qq.calls.isEmpty, 'Busy library caused an online request');
  },
  'changed local metadata requires a fresh match before any URL request':
      () async {
        final qq = FakePlaybackSource('qq');
        final resolver = TrackPlaybackResolver(
          sources: MusicSourceRegistry(qq: qq),
          matchLocal: (_, _) async => _local(playbackFile(1)),
          prepareLocal: (_) async => throw const LibraryPlaybackException(
            LibraryPlaybackErrorKind.changed,
          ),
        );
        await _throws<LibraryPlaybackException>(
          () => resolver.resolve(
            playbackTrack(1),
            OnlineQuality.standard,
            confirm: (_, _) async => null,
            isCurrent: () => true,
          ),
        );
        _check(qq.calls.isEmpty, 'Changed metadata caused an online shortcut');
      },
  'unknown measured quality asks for a version and cancellation does no I/O':
      () async {
        final qq = FakePlaybackSource('qq');
        final files = [playbackFile(1), playbackFile(2, bitrate: 320)];
        var confirmations = 0;
        final resolver = TrackPlaybackResolver(
          sources: MusicSourceRegistry(qq: qq),
          matchLocal: (track, quality) async {
            _check(quality == null, 'A requested tier became a measurement');
            return const LocalPlaybackMatcher().resolve(
              track: track.metadata,
              candidates: MatchCandidates(
                timed: files,
                unmeasured: [],
                isTruncated: false,
              ),
              mode: PlaybackQualityMode.followOnline,
            );
          },
          prepareLocal: (_) async => throw StateError('Unexpected file access'),
        );
        await _throws<PlaybackCancelled>(
          () => resolver.resolve(
            playbackTrack(1),
            OnlineQuality.high,
            confirm: (_, resolution) async {
              confirmations++;
              _check(
                resolution.status == LocalPlaybackStatus.needsConfirmation,
                'No version choice',
              );
              return null;
            },
            isCurrent: () => true,
          ),
        );
        _check(
          confirmations == 1 && qq.calls.isEmpty,
          'Cancelled choice requested a URL',
        );
      },
  'explicit online version choice skips local access': () async {
    final qq = FakePlaybackSource('qq');
    final resolver = TrackPlaybackResolver(
      sources: MusicSourceRegistry(qq: qq),
      matchLocal: (_, _) async => LocalPlaybackResolution(
        status: LocalPlaybackStatus.needsConfirmation,
        reason: LocalPlaybackReason.ambiguousQuality,
        candidates: [playbackFile(1)],
      ),
      prepareLocal: (_) async => throw StateError('Unexpected local access'),
    );
    await resolver.resolve(
      playbackTrack(1),
      OnlineQuality.standard,
      confirm: (_, _) async => const LocalPlaybackChoice.online(),
      isCurrent: () => true,
    );
    _check(qq.calls.length == 1, 'Online choice was ignored');
  },
  'stale local lookup cannot start a playback URL request': () async {
    final qq = FakePlaybackSource('qq');
    final lookup = Completer<LocalPlaybackResolution>();
    var current = true;
    final resolver = TrackPlaybackResolver(
      sources: MusicSourceRegistry(qq: qq),
      matchLocal: (_, _) => lookup.future,
      prepareLocal: (file) async => file,
    );
    final checking = _throws<PlaybackCancelled>(
      () => resolver.resolve(
        playbackTrack(1),
        OnlineQuality.standard,
        confirm: (_, _) async => null,
        isCurrent: () => current,
      ),
    );
    current = false;
    lookup.complete(
      LocalPlaybackResolution(
        status: LocalPlaybackStatus.noMatch,
        reason: LocalPlaybackReason.noCandidates,
        candidates: [],
      ),
    );
    await checking;
    _check(qq.calls.isEmpty, 'Stale lookup started a URL request');
  },
  'QQ search and vkey use the aligned MusicOne envelopes': () async {
    final transport = FakeQqTransport();
    final clock = TestClock();
    transport.reply = (request) async => request.jsonBody!.containsKey('SONG')
        ? searchResponse()
        : moduleResponse({
            'midurlinfo': [
              {
                'result': 0,
                'songmid': 'songMid001',
                'purl': 'M500media001.mp3',
              },
            ],
            'sip': ['https://audio.example/'],
          });
    final client = testClient(transport, clock);
    try {
      final page = await client.search('Song');
      final stream = await client.resolve(
        page.tracks.single,
        OnlineQuality.standard,
      );
      final params =
          (transport.requests.last.jsonBody!['req_1'] as Map)['param'] as Map;
      _check(
        params['platform'] == '23' && params['quality'] == 'M500',
        'Vkey envelope changed',
      );
      _check(
        stream.sourceId == 'qq' && transport.requests.length == 2,
        'Unexpected QQ requests',
      );
    } finally {
      client.close();
    }
  },
  'LX tx musicUrl works as a preferred registered source': () async {
    final runtime = _RecordingLxRuntime();
    final source = LxPlaybackSource(
      sourceId: 'lx:fixture',
      runtime: runtime,
      capabilities: LxQqCapabilities.fromInit({
        'sources': {
          'tx': {
            'type': 'music',
            'actions': ['musicUrl'],
            'qualitys': ['128k'],
          },
        },
      }),
      coordinator: TestClock().coordinator(),
    );
    final qq = FakePlaybackSource('qq');
    final registry = _registry(qq, source);
    try {
      final result = await registry.resolve(
        playbackTrack(1),
        OnlineQuality.standard,
        preferredSourceId: source.sourceId,
      );
      final event = runtime.events.single;
      final info = event['info'] as Map;
      _check(
        event['source'] == 'tx' && event['action'] == 'musicUrl',
        'Wrong LX event',
      );
      _check(
        info['type'] == '128k' &&
            (info['musicInfo'] as Map)['songmid'] == 'songMid1',
        'Wrong LX identity',
      );
      _check(
        result.sourceId == source.sourceId && qq.calls.isEmpty,
        'LX priority was ignored',
      );
    } finally {
      registry.close();
    }
  },
  'only five remaining songs start one incremental recommendation batch':
      () async {
        final queue = RecommendationQueue()
          ..replace(List.generate(20, (i) => playbackTrack(i + 1)));
        final batch = Completer<List<QqTrack>>();
        var calls = 0;
        final continuation = RecommendationContinuation(
          queue: queue,
          onChanged: () {},
        );
        continuation.begin(() {
          calls++;
          return batch.future;
        });
        queue.select(13);
        await continuation.check();
        _check(calls == 0, 'Prefetched with six songs remaining');
        queue.select(14);
        final first = continuation.check();
        final second = continuation.check();
        batch.complete(List.generate(20, (i) => playbackTrack(i + 21)));
        await Future.wait([first, second]);
        _check(
          calls == 1 && queue.tracks.length == 40,
          'Batch was not single-flight',
        );
        _check(queue.currentIndex == 14, 'Append interrupted the current song');
      },
  'replacing a queue discards a pending recommendation result': () async {
    final queue = RecommendationQueue()
      ..replace(List.generate(20, (i) => playbackTrack(i + 1)));
    queue.select(14);
    final batch = Completer<List<QqTrack>>();
    final continuation = RecommendationContinuation(
      queue: queue,
      onChanged: () {},
    );
    continuation.begin(() => batch.future);
    final loading = continuation.check();
    await Future<void>.delayed(Duration.zero);
    continuation.stop();
    queue.replace([playbackTrack(100)]);
    batch.complete(List.generate(20, (i) => playbackTrack(i + 21)));
    await loading;
    _check(
      queue.tracks.length == 1 && queue.tracks.single.mid == 'songMid100',
      'Stale batch entered a new queue',
    );
  },
  'cancelled continuation never starts its scheduled provider call': () async {
    final queue = RecommendationQueue()..replace([playbackTrack(1)]);
    var calls = 0;
    final continuation = RecommendationContinuation(
      queue: queue,
      onChanged: () {},
    );
    continuation.begin(() async {
      calls++;
      return [playbackTrack(2)];
    });
    final loading = continuation.check();
    continuation.stop();
    await loading;
    _check(
      calls == 0 && queue.tracks.length == 1,
      'Cancelled batch still contacted its provider',
    );
  },
  'failed recommendation batch waits for an explicit retry': () async {
    final queue = RecommendationQueue()..replace([playbackTrack(1)]);
    var calls = 0;
    final continuation = RecommendationContinuation(
      queue: queue,
      onChanged: () {},
    );
    continuation.begin(() {
      calls++;
      if (calls == 1) throw const OnlineException(OnlineErrorKind.transport);
      return Future.value([playbackTrack(2)]);
    });
    await continuation.check();
    _check(
      !continuation.isLoading && continuation.error != null,
      'Synchronous failure left a busy request',
    );
    await continuation.check();
    _check(calls == 1, 'Failure was automatically retried');
    await continuation.check(retry: true);
    _check(calls == 2 && queue.tracks.length == 2, 'Explicit retry failed');
  },
  'duplicate-only recommendation batches end automatic continuation': () async {
    final queue = RecommendationQueue()..replace([playbackTrack(1)]);
    var calls = 0;
    final continuation = RecommendationContinuation(
      queue: queue,
      onChanged: () {},
    );
    continuation.begin(() async {
      calls++;
      return [playbackTrack(1)];
    });
    await continuation.check();
    await continuation.check();
    _check(
      !continuation.isActive && calls == 1 && queue.tracks.length == 1,
      'Duplicate batch caused a fetch loop',
    );
  },
  'incremental queues stay bounded and preserve the current track': () async {
    final queue = RecommendationQueue(maxTracks: 40, maxSeenIdentities: 80)
      ..replace(List.generate(20, (i) => playbackTrack(i + 1)));
    for (var batch = 1; batch < 20; batch++) {
      queue.select(queue.tracks.length - 1);
      final current = queue.tracks[queue.currentIndex].identity;
      queue.append(List.generate(20, (i) => playbackTrack(batch * 20 + i + 1)));
      _check(queue.tracks.length <= 40, 'Queue grew without a bound');
      _check(
        queue.tracks[queue.currentIndex].identity == current,
        'Trimming removed the current song',
      );
    }
  },
  'a removed preferred source safely uses the built-in QQ resolver': () async {
    final qq = FakePlaybackSource('qq');
    await MusicSourceRegistry(qq: qq).resolve(
      playbackTrack(1),
      OnlineQuality.standard,
      preferredSourceId: 'removed',
      fallbackSourceId: 'qq',
    );
    _check(qq.calls.length == 1, 'Missing source was retried or duplicated');
  },
  'registry closes owned adapters once and keeps the shared QQ client':
      () async {
        final qq = FakePlaybackSource('qq');
        final third = FakePlaybackSource('custom');
        final registry = _registry(qq, third);
        registry.close();
        registry.close();
        _check(
          third.closeCount == 1 && qq.closeCount == 0,
          'Source ownership was violated',
        );
        final error = await _throws<OnlineException>(
          () => registry.resolve(playbackTrack(1), OnlineQuality.standard),
        );
        _check(
          error.kind == OnlineErrorKind.closed && qq.calls.isEmpty,
          'Closed registry contacted a source',
        );
      },
  'non-secret playback preferences persist and serialize concurrent saves':
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'motif-playback-preferences-',
        );
        final target = File(
          '${directory.path}${Platform.pathSeparator}preferences.json',
        );
        try {
          final store = FileOnlinePlaybackPreferencesStore(
            file: () async => target,
          );
          _check(
            (await store.load()).quality == OnlineQuality.standard,
            'Wrong default quality',
          );
          await store.save(
            const OnlinePlaybackPreferences(
              quality: OnlineQuality.lossless,
              preferredSourceId: 'custom',
              fallbackSourceId: 'qq',
            ),
          );
          final reopened = FileOnlinePlaybackPreferencesStore(
            file: () async => target,
          );
          final saved = await reopened.load();
          _check(
            saved.quality == OnlineQuality.lossless &&
                saved.preferredSourceId == 'custom' &&
                saved.fallbackSourceId == 'qq',
            'Preferences did not survive reopening',
          );
          await Future.wait([
            store.save(saved.copyWith(quality: OnlineQuality.high)),
            store.save(
              saved.copyWith(
                quality: OnlineQuality.hiRes,
                preferredSourceId: 'qq',
              ),
            ),
          ]);
          final last = await reopened.load();
          _check(
            last.quality == OnlineQuality.hiRes &&
                last.fallbackSourceId == null,
            'Save ordering or duplicate fallback failed',
          );
          _check(
            (await directory.list().toList()).length == 1,
            'Temporary preference files were retained',
          );
        } finally {
          if (await target.exists()) await target.delete();
          await directory.delete();
        }
      },
  'malformed preferences are visible errors rather than silent resets':
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'motif-playback-preferences-',
        );
        final target = File(
          '${directory.path}${Platform.pathSeparator}preferences.json',
        );
        try {
          await target.writeAsString('{invalid');
          final store = FileOnlinePlaybackPreferencesStore(
            file: () async => target,
          );
          await _throws<FormatException>(() => store.load());
          await _throws<FormatException>(
            () async => OnlinePlaybackPreferences.fromJson({
              'version': 1,
              'quality': 'invented',
              'preferredSourceId': 'qq',
            }),
          );
        } finally {
          if (await target.exists()) await target.delete();
          await directory.delete();
        }
      },
};

MusicSourceRegistry _registry(
  PlaybackUrlResolver qq,
  PlaybackUrlResolver third,
) => MusicSourceRegistry(
  qq: qq,
  thirdPartySources: [
    MusicSourceRegistration(name: 'Fixture', resolver: third),
  ],
);

LocalPlaybackResolution _local(LocalAudioFile file) => LocalPlaybackResolution(
  status: LocalPlaybackStatus.selected,
  reason: LocalPlaybackReason.uniqueVersion,
  selected: file,
  candidates: [file],
);

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<T> _throws<T>(Future<dynamic> Function() operation) async {
  try {
    await operation();
  } catch (error) {
    if (error is T) return error as T;
    throw StateError('Expected $T, received ${error.runtimeType}');
  }
  throw StateError('Expected $T');
}

class _RecordingLxRuntime implements LxScriptRuntime {
  final events = <Map<String, Object?>>[];
  @override
  Future<Object?> request(Map<String, Object?> event) async {
    events.add(event);
    return 'https://audio.example/song.mp3';
  }

  @override
  void cancelRequest() {}
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/audio_engine.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/library/domain/local_playback_matcher.dart';
import 'package:motif/online/application/online_playback_controller.dart';
import 'package:motif/online/application/track_playback_resolver.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/qq/qq_track.dart';
import 'package:motif/settings/online_playback_preferences.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import '../support/library_fixtures.dart';
import 'playback_fakes.dart';

void main() {
  late FakeAudioEngine engine;
  late FakePlaybackSource qq;
  late FakePlaybackSource custom;
  late OnlinePlaybackSettingsController settings;
  late OnlinePlaybackController playback;
  late DiagnosticRecorder diagnostics;
  late Future<LocalPlaybackResolution> Function(QqTrack) match;

  LocalPlaybackResolution noMatch() => LocalPlaybackResolution(
    status: LocalPlaybackStatus.noMatch,
    reason: LocalPlaybackReason.noCandidates,
    candidates: [],
  );

  setUp(() async {
    engine = FakeAudioEngine();
    qq = FakePlaybackSource('qq');
    custom = FakePlaybackSource('custom');
    settings = OnlinePlaybackSettingsController(
      MemoryPlaybackPreferencesStore(),
    );
    await settings.initialize();
    match = (_) async => noMatch();
    diagnostics = DiagnosticRecorder();
    playback = OnlinePlaybackController(
      engine: engine,
      diagnostics: diagnostics,
      settings: settings,
      resolver: TrackPlaybackResolver(
        sources: MusicSourceRegistry(
          qq: qq,
          thirdPartySources: [
            MusicSourceRegistration(name: 'Custom', resolver: custom),
          ],
        ),
        matchLocal: (track, _) => match(track),
        prepareLocal: (file) async => file,
      ),
      confirmLocal: (_, _) async => null,
    );
  });

  tearDown(() async {
    playback.dispose();
    playback.resolver.sources.close();
    settings.dispose();
    diagnostics.dispose();
    await engine.dispose();
  });

  test(
    'resolves only the current URL and resolves the next song on demand',
    () async {
      final tracks = List.generate(3, (i) => playbackTrack(i + 1));
      expect(await playback.playQueue(tracks), isTrue);
      expect(qq.calls, hasLength(1));
      expect(playback.queue.tracks, hasLength(3));
      expect(engine.opened, hasLength(1));

      expect(await playback.next(), isTrue);
      expect(qq.calls, hasLength(2));
      expect(playback.currentTrack?.identity, tracks[1].identity);
      expect(playback.queue.currentIndex, 1);
      expect(engine.opened.single.title, tracks[1].title);
    },
  );

  test(
    'failed replacement preserves the previous queue and can be retried',
    () async {
      final first = playbackTrack(1);
      final second = playbackTrack(2);
      await playback.playQueue([first]);
      qq.reply = (_, _) async =>
          throw const OnlineException(OnlineErrorKind.unavailable);
      expect(await playback.playQueue([second]), isFalse);
      expect(playback.currentTrack?.identity, first.identity);
      expect(playback.queue.tracks.single.identity, first.identity);
      expect(engine.openCount, 1);
      expect(
        playback.error,
        const OnlineException(OnlineErrorKind.unavailable).toString(),
      );

      qq.reply = null;
      expect(await playback.retry(), isTrue);
      expect(playback.currentTrack?.identity, second.identity);
    },
  );

  test(
    'new selection cancels stale matching before it requests a URL',
    () async {
      final lookup = Completer<LocalPlaybackResolution>();
      match = (track) =>
          track.mid == 'songMid1' ? lookup.future : Future.value(noMatch());
      final first = playback.playQueue([playbackTrack(1)]);
      await Future<void>.delayed(Duration.zero);
      expect(await playback.playQueue([playbackTrack(2)]), isTrue);
      lookup.complete(noMatch());
      expect(await first, isFalse);
      expect(qq.calls.single.$1.mid, 'songMid2');
      expect(engine.openCount, 1);
    },
  );

  test('fallback and native opening share a playback ID without exposing track identity', () async {
    diagnostics.setEnabled(true);
    await settings.save(
      const OnlinePlaybackPreferences(fallbackSourceId: 'custom'),
    );
    qq.reply = (_, _) async =>
        throw const OnlineException(OnlineErrorKind.unavailable);
    expect(await playback.playQueue([playbackTrack(1)]), isTrue);
    final log = utf8.decode(
      diagnostics.export({
        DiagnosticSection.playback: playback.diagnosticSnapshot(),
      }).bytes,
    );
    final events = (jsonDecode(log) as Map)['events'] as List;
    expect(events.map((event) => event['event']), [
      'playbackRequested',
      'localMatch',
      'sourceRequest',
      'sourceFailure',
      'sourceFallback',
      'sourceRequest',
      'sourceReady',
      'engineOpening',
      'playbackReady',
    ]);
    expect(events.every((event) => event['operationId'] == 1), isTrue);
    expect(events[2]['source'], 'qq');
    expect(events[4]['source'], 'other');
    expect(events[4]['sourceIndex'], 2);
    expect(log, isNot(contains('songMid1')));
    expect(log, isNot(contains('audio.example')));
    expect(log, isNot(contains('custom')));
  });

  test('each native completion lazily advances one catalog entry', () async {
    await playback.playQueue(List.generate(3, (i) => playbackTrack(i + 1)));
    engine.completeTrack();
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.mid, 'songMid2');
    expect(qq.calls, hasLength(2));
    engine.completeTrack();
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.mid, 'songMid3');
    expect(qq.calls, hasLength(3));
  });

  test('disposing during URL resolution prevents a late native open', () async {
    final response = Completer<OnlineStream>();
    qq.reply = (_, _) => response.future;
    final opening = playback.playQueue([playbackTrack(1)]);
    await Future<void>.delayed(Duration.zero);
    playback.dispose();
    response.complete(
      OnlineStream(
        uri: Uri.https('audio.example', '/song.mp3'),
        sourceId: 'qq',
        requestedQuality: OnlineQuality.standard,
      ),
    );
    expect(await opening, isFalse);
    expect(engine.openCount, 0);
  });

  test(
    'verified local playback opens its locator without any URL request',
    () async {
      final file = playbackFile(1);
      match = (_) async => LocalPlaybackResolution(
        status: LocalPlaybackStatus.selected,
        reason: LocalPlaybackReason.uniqueVersion,
        candidates: [file],
        selected: file,
      );
      expect(await playback.playQueue([playbackTrack(1)]), isTrue);
      expect(engine.opened.single.uri, file.location.locator);
      expect(qq.calls, isEmpty);
      expect(custom.calls, isEmpty);
    },
  );

  test(
    'replacing a recommendation queue drops the old pending batch',
    () async {
      final batch = Completer<List<QqTrack>>();
      await playback.playQueue(
        List.generate(20, (i) => playbackTrack(i + 1)),
        startIndex: 14,
        nextRecommendationBatch: () => batch.future,
      );
      final loading = playback.continuation.check();
      await Future<void>.delayed(Duration.zero);
      await playback.playQueue([playbackTrack(100)]);
      batch.complete(List.generate(20, (i) => playbackTrack(i + 21)));
      await loading;
      expect(playback.queue.tracks.single.mid, 'songMid100');
      expect(playback.continuation.isActive, isFalse);
    },
  );

  test(
    'saved source priority and requested quality are used at playback',
    () async {
      await settings.save(
        const OnlinePlaybackPreferences(
          preferredSourceId: 'custom',
          fallbackSourceId: 'qq',
          quality: OnlineQuality.lossless,
        ),
      );
      expect(await playback.playQueue([playbackTrack(1)]), isTrue);
      expect(qq.calls, isEmpty);
      expect(custom.calls.single.$2, OnlineQuality.lossless);
    },
  );

  test('opening the prototype releases pending catalog work', () async {
    final response = Completer<OnlineStream>();
    qq.reply = (_, _) => response.future;
    final opening = playback.playQueue([playbackTrack(1)]);
    await Future<void>.delayed(Duration.zero);
    playback.releaseCatalogQueue();
    await engine.openQueue([
      const AudioTrack(uri: 'file:///C:/sample.mp3', title: 'External'),
    ]);
    response.complete(
      OnlineStream(
        uri: Uri.https('audio.example', '/song.mp3'),
        sourceId: 'qq',
        requestedQuality: OnlineQuality.standard,
      ),
    );
    expect(await opening, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTitle, 'External');
    expect(engine.openCount, 1);
  });
  test(
    'a waiting old next command cannot skip a song in a replacement queue',
    () async {
      final batch = Completer<List<QqTrack>>();
      await playback.playQueue([
        playbackTrack(1),
      ], nextRecommendationBatch: () => batch.future);
      final moving = playback.next();
      await Future<void>.delayed(Duration.zero);
      await playback.playQueue([playbackTrack(100), playbackTrack(101)]);
      batch.complete([playbackTrack(2)]);
      expect(await moving, isFalse);
      expect(playback.currentTrack?.mid, 'songMid100');
      expect(qq.calls, hasLength(2));
    },
  );

  test(
    'replaying the completed last song resolves its playback URL again',
    () async {
      await playback.playQueue([playbackTrack(1)]);
      engine.completeTrack();
      await Future<void>.delayed(Duration.zero);
      await playback.togglePlay();
      expect(qq.calls, hasLength(2));
      expect(engine.openCount, 2);
    },
  );
  test('native media navigation uses the catalog queue rather than one native entry', () async {
    await playback.playQueue([playbackTrack(1), playbackTrack(2)]);
    expect(engine.applicationNavigation, isTrue);
    engine.requestNavigation(AudioQueueNavigation.next);
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.mid, 'songMid2');
    engine.requestNavigation(AudioQueueNavigation.previous);
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.mid, 'songMid1');
    expect(qq.calls, hasLength(3));
    expect(engine.opened.single.artist, 'Artist');
    expect(engine.opened.single.album, 'Album');
  });
}

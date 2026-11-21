import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_playback_source.dart';
import 'package:motif/online/qq/qq_response_parser.dart';
import 'package:motif/online/qq/qq_track.dart';

import 'online_fakes.dart';
import 'request_coordinator_test.dart' show kind;

class FakeLxRuntime implements LxScriptRuntime {
  final events = <Map<String, Object?>>[];
  int cancellations = 0;
  @override
  void cancelRequest() => cancellations++;
  late Future<Object?> Function() reply;
  @override
  Future<Object?> request(Map<String, Object?> event) {
    events.add(event);
    return reply();
  }
}

LxQqCapabilities capabilities({
  List<String> qualities = const ['128k', '320k', 'flac', 'flac24bit'],
}) => LxQqCapabilities.fromInit({
  'sources': {
    'tx': {
      'name': 'QQ 音乐',
      'type': 'music',
      'actions': ['musicUrl'],
      'qualitys': qualities,
    },
  },
});

void main() {
  test(
    'requires QQ tx source, musicUrl capability and documented qualitys field',
    () {
      expect(capabilities().qualities, OnlineQuality.values.toSet());
      expect(
        () => LxQqCapabilities.fromInit({
          'sources': {
            'qq': {
              'type': 'music',
              'actions': ['musicUrl'],
              'qualitys': ['128k'],
            },
          },
        }),
        throwsA(kind(OnlineErrorKind.unsupported)),
      );
      expect(
        () => LxQqCapabilities.fromInit({
          'sources': {
            'tx': {
              'type': 'music',
              'actions': ['musicUrl'],
              'qualities': ['128k'],
            },
          },
        }),
        throwsA(kind(OnlineErrorKind.unsupported)),
      );
    },
  );

  test(
    'maps QQ metadata to LX legacy musicInfo without downloading any details',
    () {
      final info = lxQqMusicInfo(parseQqTrack(songJson()));
      expect(info['source'], 'tx');
      expect(info['songmid'], 'songMid001');
      expect(info['songId'], 42);
      expect(info['strMediaMid'], 'media001');
      expect(info['singer'], 'Artist');
      expect(info['albumName'], 'Album');
      expect(info['albumMid'], 'album001');
      expect(info['interval'], '03:00');
      expect((info['types'] as List).length, 4);
      expect((info['_types'] as Map).containsKey('320k'), isTrue);
      expect(info['typeUrl'], isEmpty);
    },
  );

  test('one supported quality emits exactly one tx musicUrl request and joins repeats', () async {
    final runtime = FakeLxRuntime()
      ..reply = () async => 'https://audio.example/song.flac';
    final source = LxPlaybackSource(
      sourceId: 'lx:fixture',
      runtime: runtime,
      capabilities: capabilities(),
      coordinator: TestClock().coordinator(),
    );
    addTearDown(source.close);
    final track = parseQqTrack(songJson());
    final values = await Future.wait([
      source.resolve(track, OnlineQuality.lossless),
      source.resolve(track, OnlineQuality.lossless),
    ]);
    expect(runtime.events.length, 1);
    expect(runtime.events.single['source'], 'tx');
    expect(runtime.events.single['action'], 'musicUrl');
    expect((runtime.events.single['info'] as Map)['type'], 'flac');
    expect(values.first.sourceId, 'lx:fixture');
    expect(values.first.reportedQuality, isNull);
  });

  test(
    'unsupported tier and incomplete metadata never invoke the runtime',
    () async {
      final runtime = FakeLxRuntime()
        ..reply = () async => 'https://audio.example/song.mp3';
      final source = LxPlaybackSource(
        sourceId: 'lx:fixture',
        runtime: runtime,
        capabilities: capabilities(qualities: ['128k']),
      );
      addTearDown(source.close);
      await expectLater(
        source.resolve(parseQqTrack(songJson()), OnlineQuality.hiRes),
        throwsA(kind(OnlineErrorKind.unsupported)),
      );
      final missing = QqTrack(
        mid: 'songMid001',
        title: 'Song',
        artists: ['Artist'],
        album: 'Album',
      );
      await expectLater(
        source.resolve(missing, OnlineQuality.standard),
        throwsA(kind(OnlineErrorKind.unavailable)),
      );
      expect(runtime.events, isEmpty);
    },
  );

  for (final result in [
    'file:///private/song',
    'javascript:alert(1)',
    'https://user:password@audio.example/song',
    'https://audio.example/song\n',
    {'url': 'https://audio.example/song'},
  ]) {
    test(
      'rejects invalid runtime results without probing fallback: $result',
      () async {
        final runtime = FakeLxRuntime()..reply = () async => result;
        final source = LxPlaybackSource(
          sourceId: 'lx:fixture',
          runtime: runtime,
          capabilities: capabilities(),
        );
        addTearDown(source.close);
        final track = parseQqTrack(songJson());
        for (var i = 0; i < 2; i++) {
          await expectLater(
            source.resolve(track, OnlineQuality.standard),
            throwsA(kind(OnlineErrorKind.malformedResponse)),
          );
        }
        expect(runtime.events.length, 1);
      },
    );
  }

  test(
    'runtime limit signals pause subsequent songs without leaking raw errors',
    () async {
      final runtime = FakeLxRuntime()
        ..reply = () async =>
            throw const OnlineException(OnlineErrorKind.rateLimited);
      final source = LxPlaybackSource(
        sourceId: 'lx:fixture',
        runtime: runtime,
        capabilities: capabilities(),
        coordinator: TestClock().coordinator(),
      );
      addTearDown(source.close);
      await expectLater(
        source.resolve(parseQqTrack(songJson()), OnlineQuality.standard),
        throwsA(kind(OnlineErrorKind.rateLimited)),
      );
      await expectLater(
        source.resolve(
          parseQqTrack(songJson(mid: 'songMid002')),
          OnlineQuality.standard,
        ),
        throwsA(kind(OnlineErrorKind.rateLimited)),
      );
      expect(runtime.events.length, 1);
    },
  );

  test(
    'script timeout cancels work and is not automatically retried',
    () async {
      final pending = Completer<Object?>();
      final runtime = FakeLxRuntime()..reply = () => pending.future;
      final source = LxPlaybackSource(
        sourceId: 'lx:fixture',
        runtime: runtime,
        capabilities: capabilities(),
        requestTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(source.close);
      final track = parseQqTrack(songJson());
      await expectLater(
        source.resolve(track, OnlineQuality.standard),
        throwsA(kind(OnlineErrorKind.transport)),
      );
      await expectLater(
        source.resolve(track, OnlineQuality.standard),
        throwsA(kind(OnlineErrorKind.transport)),
      );
      expect(runtime.cancellations, 1);
      expect(runtime.events.length, 1);
      pending.complete('https://audio.example/late.mp3');
    },
  );

  test('late script result after close is discarded', () async {
    final started = Completer<void>();
    final pending = Completer<Object?>();
    final runtime = FakeLxRuntime()
      ..reply = () {
        started.complete();
        return pending.future;
      };
    final source = LxPlaybackSource(
      sourceId: 'lx:fixture',
      runtime: runtime,
      capabilities: capabilities(),
    );
    final result = source.resolve(
      parseQqTrack(songJson()),
      OnlineQuality.standard,
    );
    final check = expectLater(result, throwsA(kind(OnlineErrorKind.closed)));
    await started.future;
    source.close();
    pending.complete('https://audio.example/late.mp3');
    await check;
    expect(runtime.cancellations, 1);
  });
}

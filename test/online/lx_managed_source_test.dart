import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/audio_engine.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/library/domain/local_playback_matcher.dart';
import 'package:motif/online/application/online_playback_controller.dart';
import 'package:motif/online/application/track_playback_resolver.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_network.dart';
import 'package:motif/online/lx/lx_source_manager.dart';
import 'package:motif/online/lx/lx_source_store.dart';
import 'package:motif/online/qq/qq_track.dart';
import 'package:motif/settings/online_playback_preferences.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import '../support/library_fixtures.dart';
import 'playback_fakes.dart';

const _api = 'api.example.test';
const _media = 'audio.example.test';
const _script = '/*!\n * @name Test source\n * @version 1.0\n */\n';
const _capabilities = {
  'capabilities': {
    'sources': {
      'tx': {
        'type': 'music',
        'actions': ['musicUrl'],
        'qualitys': ['128k', '320k'],
      },
    },
  },
};

void main() {
  late Directory root;
  late LxSourceStore store;
  late MusicSourceRegistry registry;
  late LxSourceManager manager;
  late _QqSource qq;
  late List<Uri> fetched;
  late List<Uri> opened;
  late int initialized;
  late int handled;
  late bool blocked;
  late Completer<void>? paused;
  late Completer<void> started;
  late QqTrack track;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('motif-lx-managed-');
    store = LxSourceStore(() async => root);
    qq = _QqSource();
    registry = MusicSourceRegistry(qq: qq);
    fetched = [];
    opened = [];
    initialized = 0;
    handled = 0;
    blocked = false;
    paused = null;
    started = Completer<void>();
    track = QqTrack(
      mid: 'song',
      title: 'Song',
      artists: ['Artist'],
      album: 'Album',
    );
    manager = LxSourceManager(
      store: store,
      registry: registry,
      run:
          (
            bytes, {
            required info,
            event,
            required onRequest,
            required cancellation,
          }) async {
            if (event == null) {
              initialized++;
              expect(
                await onRequest({
                  'url': 'https://$_api/update',
                  'options': <String, Object?>{},
                }, cancellation),
                {'error': 'denied'},
              );
              return utf8.decode(bytes).contains('invalid')
                  ? {'error': 'init'}
                  : _capabilities;
            }
            handled++;
            expect(event['source'], 'tx');
            expect(event['action'], 'musicUrl');
            final info = event['info']! as Map<String, Object?>;
            expect(info['type'], '128k');
            expect((info['musicInfo']! as Map)['songmid'], 'song');
            if (paused case final gate?) {
              started.complete();
              await cancellation.until(gate.future);
            }
            expect(
              await onRequest({
                'url': 'http://127.0.0.1',
                'options': <String, Object?>{},
              }, cancellation),
              {'error': 'denied'},
            );
            final response = await onRequest({
              'url': 'https://$_api/track',
              'options': <String, Object?>{},
            }, cancellation);
            expect(
              await onRequest({
                'url': 'https://$_api/repeat',
                'options': <String, Object?>{},
              }, cancellation),
              {'error': 'denied'},
            );
            return response.containsKey('response')
                ? {'url': 'https://$_media/track.wav'}
                : {'error': 'unavailable'};
          },
      fetch: (request, _) async {
        fetched.add(request.uri);
        if (blocked) throw const OnlineException(OnlineErrorKind.rateLimited);
        return {
          'statusCode': 200,
          'body': {'ok': true},
        };
      },
      open: (uri, hosts, owner, _) async {
        expect(hosts, {_media});
        expect(owner.cancelled, isFalse);
        opened.add(uri);
        return _Input();
      },
    );
  });

  tearDown(() async {
    manager.dispose();
    registry.close();
    await root.delete(recursive: true);
  });

  Future<String> enable({String? media = _media}) async {
    expect(await manager.import(utf8.encode(_script)), isTrue);
    expect(initialized, 0);
    final saved = manager.sources.single;
    expect(saved.enabled, isFalse);
    expect(registry.contains(saved.id), isFalse);
    expect(
      await manager.configure(
        saved.id,
        grant: LxSourceGrant(api: [_api], media: [?media]),
        enable: true,
      ),
      isTrue,
    );
    expect(initialized, 1);
    expect(fetched, isEmpty);
    return saved.id;
  }

  test(
    'QQ success leaves the backup idle and a recoverable miss opens only PCM',
    () async {
      final id = await enable();
      final first = await registry.resolve(
        track,
        OnlineQuality.standard,
        fallbackSourceId: id,
      );
      expect(first.sourceId, 'qq');
      expect(handled, 0);

      qq.fail = true;
      final stream = await registry.resolve(
        track,
        OnlineQuality.standard,
        fallbackSourceId: id,
      ) as ControlledOnlineStream;
      expect(handled, 1);
      expect(fetched, [Uri.parse('https://$_api/track')]);
      expect(opened, [Uri.parse('https://$_media/track.wav')]);
      expect(stream.uri.scheme, 'motif-controlled');
      expect(stream.uri.host, isEmpty);
      expect(stream.owner.cancelled, isFalse);

      expect(
        await manager.configure(
          id,
          grant: manager.sources.single.grant,
          enable: false,
        ),
        isTrue,
      );
      expect(stream.owner.cancelled, isTrue);
      stream.input.close();
      expect((await store.load()).single.enabled, isFalse);
      qq.fail = false;
      expect(
        (await registry.resolve(
          track,
          OnlineQuality.standard,
          preferredSourceId: id,
        )).sourceId,
        'qq',
      );
    },
  );

  test(
    'unknown media host and API rate limits terminate without QQ fallback',
    () async {
      final id = await enable(media: null);
      Future<OnlineStream> resolve() => registry.resolve(
        track,
        OnlineQuality.standard,
        preferredSourceId: id,
        fallbackSourceId: 'qq',
      );
      await expectLater(
        resolve(),
        throwsA(
          isA<LxHostPermissionError>().having(
            (error) => error.host,
            'host',
            _media,
          ),
        ),
      );
      expect(opened, isEmpty);
      expect(qq.calls, 0);
      blocked = true;
      await expectLater(
        resolve(),
        throwsA(
          isA<OnlineException>().having(
            (error) => error.kind,
            'kind',
            OnlineErrorKind.rateLimited,
          ),
        ),
      );
      expect(fetched, hasLength(2));
      expect(qq.calls, 0);
    },
  );

  test(
    'a failed replacement keeps the active grant and a valid change revokes it',
    () async {
      final id = await enable();
      final stream = await registry.resolve(
        track,
        OnlineQuality.standard,
        preferredSourceId: id,
      ) as ControlledOnlineStream;
      final original = manager.sources.single;
      expect(
        await manager.import(utf8.encode('$_script invalid;'), replaceId: id),
        isFalse,
      );
      expect(registry.contains(id), isTrue);
      expect(stream.owner.cancelled, isFalse);
      expect(
        await manager.import(utf8.encode('$_script // new'), replaceId: id),
        isTrue,
      );
      expect(registry.contains(id), isFalse);
      expect(stream.owner.cancelled, isTrue);
      stream.input.close();
      final saved = (await store.load()).single;
      expect(saved.id, id);
      expect(saved.digest, isNot(original.digest));
      expect(saved.grant.api, isEmpty);
      expect(saved.grant.media, isEmpty);
      expect(saved.enabled, isFalse);
      expect(await manager.remove(id), isTrue);
      expect(await store.load(), isEmpty);
      expect(
        await root.list().where((file) => file.path.endsWith('.js')).isEmpty,
        isTrue,
      );
    },
  );

  test(
    'superseded playback and a changed grant release in-flight requests',
    () async {
      final id = await enable();
      final cancel = PcmCancellation();
      paused = Completer<void>();
      final resolving = registry.resolve(
        track,
        OnlineQuality.standard,
        preferredSourceId: id,
        cancellation: cancel,
      );
      final assertion = expectLater(resolving, throwsA(isA<PcmCancelled>()));
      await started.future;
      cancel.cancel();
      await assertion;
      paused!.complete();
      started = Completer<void>();
      paused = Completer<void>();
      final previousGrant = registry.resolve(
        track,
        OnlineQuality.standard,
        preferredSourceId: id,
      );
      final revoked = expectLater(
        previousGrant,
        throwsA(
          isA<OnlineException>().having(
            (error) => error.kind,
            'kind',
            OnlineErrorKind.closed,
          ),
        ),
      );
      await started.future;
      expect(
        await manager.configure(id, grant: LxSourceGrant(), enable: true),
        isTrue,
      );
      await revoked;
      paused!.complete();
      expect(initialized, 1);
      expect(fetched, isEmpty);
    },
  );

  test('catalog playback prefers local files then uses the controlled player entry', () async {
    final id = await enable();
    final settings = OnlinePlaybackSettingsController(
      MemoryPlaybackPreferencesStore(),
    );
    await settings.initialize();
    await settings.save(OnlinePlaybackPreferences(preferredSourceId: id));
    final engine = _ControlledPlayer();
    final local = playbackFile(1);
    var matched = true;
    final controller = OnlinePlaybackController(
      engine: engine,
      settings: settings,
      resolver: TrackPlaybackResolver(
        sources: registry,
        matchLocal: (_, _) async => matched
            ? LocalPlaybackResolution(
                status: LocalPlaybackStatus.selected,
                reason: LocalPlaybackReason.uniqueVersion,
                candidates: [local],
                selected: local,
              )
            : LocalPlaybackResolution(
                status: LocalPlaybackStatus.noMatch,
                reason: LocalPlaybackReason.noCandidates,
                candidates: [],
              ),
        prepareLocal: (file) async => file,
      ),
      confirmLocal: (_, _) async => null,
    );
    addTearDown(() async {
      controller.dispose();
      settings.dispose();
      await engine.dispose();
    });
    expect(await controller.playQueue([track]), isTrue);
    expect(engine.opened.single.uri, local.location.locator);
    expect(fetched, isEmpty);

    matched = false;
    expect(await controller.playQueue([track]), isTrue);
    expect(engine.bound, isNotNull);
    expect(engine.opened.single.uri, startsWith('motif-controlled:'));
    expect(qq.calls, 0);
    expect(controller.currentTrack?.identity, track.identity);

    expect(await manager.remove(id), isTrue);
    expect(engine.revoked, isTrue);
    expect(await controller.playQueue([track]), isTrue);
    expect(engine.opened.single.uri, startsWith('https://qq.example.test/'));
    expect(fetched, hasLength(1));
  });

  test(
    'host allowlist cannot be widened by an authority or request header',
    () {
      for (final raw in [
        'https://user@$_api/t',
        'http://$_api/t',
        'https://$_api:444/t',
        'https://127.0.0.1/t',
        'https://$_api/t#secret',
        'https://$_api\\other/t',
      ]) {
        expect(checkedLxUrl(raw), isNull);
      }
      for (final address in [
        '127.0.0.1',
        '172.16.0.1',
        '::ffff:8.8.8.8',
        'fc00::1',
        '192.0.2.1',
      ]) {
        expect(isPublicLxAddress(InternetAddress(address)), isFalse);
      }
      expect(
        () => LxApiRequest.parse(
          {
            'url': 'https://$_api/t',
            'options': {
              'headers': {'Authorization': 'fixture-only'},
            },
          },
          {_api},
        ),
        throwsA(isA<OnlineException>()),
      );
      final form = LxApiRequest.parse(
        {
          'url': 'https://$_api/t',
          'options': {
            'method': 'post',
            'form': {'title': 'a+b', 'empty': ''},
          },
        },
        {_api},
      );
      expect(utf8.decode(form.body!), 'title=a%2Bb&empty=');
    },
  );
}

final class _QqSource implements PlaybackUrlResolver {
  int calls = 0;
  bool fail = false;
  @override
  String get sourceId => 'qq';
  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) async {
    calls++;
    if (fail) throw const OnlineException(OnlineErrorKind.unavailable);
    return OnlineStream(
      uri: Uri.parse('https://qq.example.test/audio'),
      sourceId: sourceId,
      requestedQuality: quality,
    );
  }

  @override
  void close() {}
}

final class _Input implements ControlledPcmInput {
  @override
  int get channels => 2;
  @override
  int get frames => 32000;
  @override
  int get sampleRate => 16000;
  @override
  bool get seekable => true;
  @override
  void close() {}
  @override
  Future<ControlledPcmRead> openAt(int frame, PcmCancellation cancellation) =>
      throw UnimplementedError();
}

final class _ControlledPlayer extends FakeAudioEngine
    implements ControlledPcmAudioEngine {
  ControlledPcmInput? bound;
  bool revoked = false;

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
    opening?.check();
    bound = input;
    cancellation?.listen(() {
      revoked = true;
      input.close();
    });
    await super.openQueue([
      AudioTrack(uri: identity!, title: title, artist: artist, album: album),
    ]);
  }
}

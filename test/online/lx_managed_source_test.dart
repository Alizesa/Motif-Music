import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/audio_engine.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/audio/controlled_encoded.dart';
import 'package:motif/library/domain/local_playback_matcher.dart';
import 'package:motif/online/application/online_playback_controller.dart';
import 'package:motif/online/application/track_playback_resolver.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_network.dart';
import 'package:motif/online/lx/lx_audio_media.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';
import 'package:motif/online/lx/lx_source_manager.dart';
import 'package:motif/online/lx/lx_source_store.dart';
import 'package:motif/online/qq/qq_track.dart';
import 'package:motif/settings/online_playback_preferences.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import '../support/library_fixtures.dart';
import '../support/lx_encoded_fixture.dart';
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
  late String mediaUrl;
  late int requestAttempts;
  var unsupportedFirst = false;
  ControlledAudioInput? mediaInput;

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
    unsupportedFirst = false;
    mediaInput = null;
    mediaUrl = 'https://$_media/track.wav';
    requestAttempts = 1;
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
            if (unsupportedFirst) {
              expect(
                await onRequest({
                  'url': 'https://$_api/first',
                  'options': {
                    'headers': {'Authorization': 'fixture-only'},
                  },
                }, cancellation),
                {'error': 'denied'},
              );
            }
            final response = await onRequest({
              'url': 'https://$_api/track',
              'options': <String, Object?>{},
            }, cancellation);
            for (var i = 1; i < requestAttempts; i++) {
              final next = await onRequest({
                'url': 'https://candidate$i.example.test/track',
                'options': <String, Object?>{},
              }, cancellation);
              expect(next.containsKey('response'), i < 4 && !blocked);
            }
            return response.containsKey('response')
                ? {'url': mediaUrl}
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
      open: (uri, owner, _) async {
        expect(owner.cancelled, isFalse);
        opened.add(uri);
        return mediaInput ?? _Input();
      },
    );
  });

  tearDown(() async {
    manager.dispose();
    registry.close();
    await root.delete(recursive: true);
  });

  Future<String> enable() async {
    expect(await manager.import(utf8.encode(_script)), isTrue);
    final saved = manager.sources.single;
    expect(saved.enabled, isTrue);
    expect(registry.contains(saved.id), isTrue);
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

      expect(await manager.configure(id, enable: false), isTrue);
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
    'unsafe media URLs and API rate limits terminate without QQ fallback',
    () async {
      final id = await enable();
      mediaUrl = 'https://127.0.0.1/track.wav';
      Future<OnlineStream> resolve() => registry.resolve(
        track,
        OnlineQuality.standard,
        preferredSourceId: id,
        fallbackSourceId: 'qq',
      );
      await expectLater(
        resolve(),
        throwsA(
          isA<OnlineException>().having(
            (error) => error.kind,
            'kind',
            OnlineErrorKind.rejected,
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

  test('a failed replacement keeps playback and a valid replacement is ready immediately', () async {
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
    expect(registry.contains(id), isTrue);
    expect(stream.owner.cancelled, isTrue);
    stream.input.close();
    final saved = (await store.load()).single;
    expect(saved.id, id);
    expect(saved.digest, isNot(original.digest));
    expect(saved.qualities, isNotEmpty);
    expect(saved.enabled, isTrue);
    expect(await manager.remove(id), isTrue);
    expect(await store.load(), isEmpty);
    expect(
      await root.list().where((file) => file.path.endsWith('.js')).isEmpty,
      isTrue,
    );
  });

  test(
    'superseded playback and disabling a source release in-flight requests',
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
      expect(await manager.configure(id, enable: false), isTrue);
      await revoked;
      paused!.complete();
      expect(initialized, 1);
      expect(fetched, isEmpty);
    },
  );

  for (final format in [null, ...ControlledAudioFormat.values]) {
    test(
      'catalog playback prefers local files then uses the controlled ${format?.name ?? 'PCM'} entry',
      () async {
        if (format != null) {
          mediaInput = await openLxAudio(
            EncodedFixtureTransport(
              format == ControlledAudioFormat.mp3
                  ? mp3Fixture()
                  : flacFixture(),
            ),
            PcmCancellation(),
          );
        }
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
        expect(
          engine.opened.single.uri,
          startsWith('https://qq.example.test/'),
        );
        expect(fetched, hasLength(1));
      },
    );
  }

  test(
    'an unsupported requested tier is reported before any API or media request',
    () async {
      final id = await enable();
      await expectLater(
        registry.resolve(track, OnlineQuality.lossless, preferredSourceId: id),
        throwsA(
          isA<OnlineException>().having(
            (error) => error.kind,
            'kind',
            OnlineErrorKind.unsupportedQuality,
          ),
        ),
      );
      expect(fetched, isEmpty);
      expect(opened, isEmpty);
      expect(handled, 0);
    },
  );

  test('unsafe URLs and application credential headers are still rejected', () {
    for (final raw in [
      'https://user@$_api/t',
      'http://$_api:81/t',
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
      () => LxApiRequest.parse({
        'url': 'https://$_api/t',
        'options': {
          'headers': {'Authorization': 'fixture-only'},
        },
      }),
      throwsA(isA<OnlineException>()),
    );
    final form = LxApiRequest.parse({
      'url': 'https://$_api/t',
      'options': {
        'method': 'post',
        'form': {'title': 'a+b', 'empty': ''},
      },
    });
    expect(utf8.decode(form.body!), 'title=a%2Bb&empty=');
  });

  test('new API and media hosts work without a saved domain list, with a bounded budget', () async {
    final id = await enable();
    requestAttempts = 5;
    mediaUrl = 'https://new-cdn.example.test/song.wav';
    final stream = await registry.resolve(
      track,
      OnlineQuality.standard,
      preferredSourceId: id,
    ) as ControlledOnlineStream;
    expect(fetched.map((uri) => uri.host), [
      _api,
      'candidate1.example.test',
      'candidate2.example.test',
      'candidate3.example.test',
    ]);
    expect(opened.single.host, 'new-cdn.example.test');
    stream.input.close();
  });

  test('a callback for an unsupported first candidate does not block a compatible next request', () async {
    final id = await enable();
    unsupportedFirst = true;
    final stream = await registry.resolve(
      track,
      OnlineQuality.standard,
      preferredSourceId: id,
    ) as ControlledOnlineStream;
    expect(fetched, [Uri.parse('https://$_api/track')]);
    expect(opened, hasLength(1));
    stream.input.close();
  });

  test('an invalid first import does not leave a disabled or half-installed source', () async {
    expect(await manager.import(utf8.encode('$_script invalid;')), isFalse);
    expect(manager.error, '脚本初始化失败。');
    expect(manager.sources, isEmpty);
    expect(await store.load(), isEmpty);
    expect(fetched, isEmpty);
  });

  test(
    'old catalogs load without domain approval and save the new source schema',
    () async {
      final id = await enable();
      final old = manager.sources.single.toJson()
        ..['api'] = ['no longer a domain list']
        ..['media'] = [];
      await File('${root.path}/sources.json').writeAsString(
        jsonEncode({
          'schema': 1,
          'sources': [old],
        }),
      );
      final loaded = await store.load();
      expect(loaded.single.id, id);
      expect(loaded.single.enabled, isTrue);
      expect(loaded.single.qualities, isNotEmpty);
      await store.save(loaded);
      final saved = jsonDecode(
        await File('${root.path}/sources.json').readAsString(),
      ) as Map;
      expect(saved['schema'], 2);
      expect((saved['sources'] as List).single, isNot(contains('api')));
      expect((saved['sources'] as List).single, isNot(contains('media')));
    },
  );

  test(
    'media redirects can move to a new public HTTPS host without user setup',
    () async {
      final calls = <Uri>[];
      final readers = <_Read>[];
      final owner = PcmCancellation();
      final transport = LxMediaTransport(
        Uri.https('audio.example.test', '/song'),
        owner,
        open: (uri, headers, scope) async {
          scope.check();
          calls.add(uri);
          final reader = _Read();
          readers.add(reader);
          return FixtureRangeResponse(
            status: calls.length == 1 ? 302 : 206,
            headers: calls.length == 1
                ? {
                    'location': ['https://other-cdn.example.test/song'],
                  }
                : {},
            body: reader,
          );
        },
      );
      final response = await transport.open(0, null, PcmCancellation());
      expect(calls.map((uri) => uri.host), [
        'audio.example.test',
        'other-cdn.example.test',
      ]);
      expect(readers.first.closed, isTrue);
      expect(response.status, 206);
      response.body.close();
      expect(readers.last.closed, isTrue);
      owner.cancel();
    },
  );

  test('automatic media destinations still reject unsafe redirects before opening them', () async {
    for (final target in [
      'https://127.0.0.1/song',
      'http://public.example.test:81/song',
      'https://user@other.example.test/song',
      'file:///etc/passwd',
    ]) {
      final calls = <Uri>[];
      final first = _Read();
      final owner = PcmCancellation();
      final transport = LxMediaTransport(
        Uri.https('audio.example.test', '/song'),
        owner,
        open: (uri, _, _) async {
          calls.add(uri);
          return FixtureRangeResponse(
            status: 302,
            headers: {
              'location': [target],
            },
            body: first,
          );
        },
      );
      await expectLater(
        transport.open(0, null, PcmCancellation()),
        throwsA(isA<OnlineException>()),
      );
      expect(calls, hasLength(1));
      expect(first.closed, isTrue);
      owner.cancel();
    }
  });
}

final class _Read implements ControlledPcmRead {
  bool closed = false;
  @override
  Future<Uint8List> read(int maximum) async => Uint8List(0);
  @override
  void close() => closed = true;
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
    implements ControlledPcmAudioEngine, ControlledEncodedAudioEngine {
  ControlledAudioInput? bound;
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
  }) => _open(
    input,
    title: title,
    artist: artist,
    album: album,
    identity: identity!,
    cancellation: cancellation,
    opening: opening,
  );

  @override
  Future<void> openControlledEncoded(
    ControlledEncodedInput input, {
    required String title,
    String? artist,
    String? album,
    required String identity,
    PcmCancellation? cancellation,
    PcmCancellation? opening,
  }) => _open(
    input,
    title: title,
    artist: artist,
    album: album,
    identity: identity,
    cancellation: cancellation,
    opening: opening,
  );

  Future<void> _open(
    ControlledAudioInput input, {
    required String title,
    String? artist,
    String? album,
    required String identity,
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
      AudioTrack(uri: identity, title: title, artist: artist, album: album),
    ]);
  }
}

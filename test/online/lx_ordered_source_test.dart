import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_encoded.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/fixture/lx_fixture_wave.dart';
import 'package:motif/online/lx/lx_music_platform.dart';
import 'package:motif/online/lx/lx_ordered_source.dart';
import 'package:motif/online/lx/lx_platform_catalog.dart';
import 'package:motif/online/lx/lx_request_error.dart';
import 'package:motif/online/lx/lx_source_manager.dart';
import 'package:motif/online/lx/lx_source_store.dart';

import '../support/lx_catalog_fixture.dart';
import '../support/lx_encoded_fixture.dart';
import 'playback_fakes.dart';

Uint8List _highMp3() {
  final frame = Uint8List(1044)..setAll(0, [255, 251, 224, 0]);
  return (BytesBuilder()
        ..add([73, 68, 51, 4, 0, 0, 0, 0, 0, 3, 1, 2, 3])
        ..add(Uint8List.fromList([for (var i = 0; i < 460; i++) ...frame])))
      .takeBytes();
}

void main() {
  late Directory temp;
  late MusicSourceRegistry registry;
  late LxSourceManager manager;
  late CatalogFixture catalog;
  late FakePlaybackSource qq;
  late Map<String, String> ids;
  late List<String> order, attempts, opens;
  late Map<String, Uint8List> media;
  late Map<String, int> status;
  late List<EncodedFixtureTransport> bodies;
  late Set<String> unavailable;
  late PcmCancellation owner;
  late BytesBuilder saved;
  late List<int> totals;
  late int? duration;
  bool truncate = false;
  Future<void> Function(PcmCancellation)? beforeMedia;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motif-order-');
    qq = FakePlaybackSource('qq');
    registry = MusicSourceRegistry(qq: qq);
    catalog = CatalogFixture()
      ..rows[LxPlatform.kw] = [
        kwRow({'DURATION': '12'}),
      ];
    ids = {};
    attempts = [];
    opens = [];
    unavailable = {};
    status = {};
    bodies = [];
    duration = 12000;
    owner = PcmCancellation();
    saved = BytesBuilder();
    totals = [];
    truncate = false;
    beforeMedia = null;
    media = {'A': mp3Fixture(), 'B': mp3Fixture(), 'C': mp3Fixture()};
    manager = LxSourceManager(
      store: LxSourceStore(() async => temp),
      registry: registry,
      catalog: LxPlatformCatalog(open: catalog.open),
      fetch: (_, _) => throw StateError('unexpected script HTTP'),
      run:
          (
            _, {
            required info,
            event,
            required onRequest,
            required cancellation,
          }) async {
            if (event == null) {
              return {
                'capabilities': {
                  'sources': {
                    for (final p in ['tx', 'kw'])
                      p: {
                        'type': 'music',
                        'actions': ['musicUrl'],
                        'qualitys': ['128k', '320k', 'flac'],
                      },
                  },
                },
              };
            }
            final name = info['name']!;
            final p = event['source'];
            final tier = (event['info'] as Map)['type'];
            attempts.add('$p/$name/$tier');
            if (unavailable.contains('$p/$name')) {
              return {'error': 'unavailable'};
            }
            return {'url': 'https://media.fixture.invalid/$name'};
          },
      mediaOpen: (uri, headers, scope) async {
        final name = uri.pathSegments.single;
        opens.add(name);
        await beforeMedia?.call(scope);
        scope.check();
        final bytes = media[name]!;
        final transport = EncodedFixtureTransport(bytes)
          ..ranges = false
          ..fault = status[name]?.toString();
        bodies.add(transport);
        final reply = await transport.open(0, null, scope);
        return truncate
            ? FixtureRangeResponse(
                status: 200,
                headers: {
                  ...reply.headers,
                  'content-length': ['${bytes.length + 200}'],
                },
                body: reply.body,
              )
            : reply;
      },
    );
    for (final name in ['C', 'B', 'A']) {
      expect(
        await manager.import(utf8.encode('/*\n * @name $name\n */')),
        isTrue,
      );
      ids[name] = manager.sources.last.id;
    }
    order = [ids['A']!, ids['B']!];
  });
  tearDown(() async {
    owner.cancel();
    manager.dispose();
    registry.close();
    await temp.delete(recursive: true);
  });
  Future<ControlledOnlineStream> play() async => await registry.resolve(
    catalogTrack(duration: duration),
    OnlineQuality.standard,
    preferredSourceId: lxOrderedSourceId,
    fallbackSourceId: 'qq',
    scriptOrder: order,
    cancellation: owner,
  ) as ControlledOnlineStream;
  Future<String> download({
    OnlineQuality quality = OnlineQuality.standard,
    Future<void> Function(Uint8List)? write,
    String source = lxOrderedSourceId,
  }) => registry.download(
    source,
    catalogTrack(duration: duration),
    quality,
    scriptOrder: order,
    cancellation: owner,
    onTotal: totals.add,
    write: write ?? (chunk) async => saved.add(chunk),
  );

  test('backup selection drives playback in its saved order without selecting a mode', () async {
    Future<OnlineStream> run(List<String> back) => registry.resolve(
      catalogTrack(duration: duration),
      OnlineQuality.standard,
      fallbackOrder: back,
      cancellation: owner,
    );
    expect((await run(order)).sourceId, 'qq');
    expect(opens, isEmpty);
    qq.reply = (_, _) async =>
        throw const OnlineException(OnlineErrorKind.unavailable);
    media['A'] = Uint8List.sublistView(mp3Fixture(), 0, 74 + 417 * 100);
    final first =
        await run([ids['A']!, ids['B']!, ids['B']!]) as ControlledOnlineStream;
    expect(first.sourceId, ids['B']);
    expect(opens, ['A', 'B']);
    expect(bodies.first.readers.single.closed, isTrue);
    first.input.close();
    opens.clear();
    final next = await run([ids['B']!, ids['A']!]) as ControlledOnlineStream;
    expect(opens, ['B']);
    next.input.close();
    expect(registry.downloadDefault('qq', order), lxOrderedSourceId);
    expect(registry.downloadDefault(ids['A']!, ['qq']), ids['A']);
  });

  test('temporarily disabling a checked backup does not discard download validation', () async {
    await manager.configure(ids['B']!, enable: false);
    expect(registry.downloadDefault(ids['A']!, [ids['B']!]), lxOrderedSourceId);
    expect(registry.orderedQualities([ids['A']!, ids['B']!]), isNotEmpty);
  });

  test(
    'an explicitly placed QQ backup is a boundary between script groups',
    () async {
      unavailable.addAll(['tx/A', 'kw/A']);
      final stream = await registry.resolve(
        catalogTrack(duration: duration),
        OnlineQuality.standard,
        preferredSourceId: ids['A']!,
        fallbackOrder: ['qq', ids['B']!],
        cancellation: owner,
      );
      expect(stream.sourceId, 'qq');
      expect(attempts, ['tx/A/128k', 'kw/A/128k']);
      expect(qq.calls.length, 1);
      expect(opens, isEmpty);
    },
  );

  test(
    'a missing primary never inserts unselected QQ in a user-edited order',
    () async {
      final stream = await registry.resolve(
        catalogTrack(duration: duration),
        OnlineQuality.standard,
        preferredSourceId: 'gone',
        fallbackOrder: ['also-gone', ids['B']!],
        cancellation: owner,
      ) as ControlledOnlineStream;
      expect(stream.sourceId, ids['B']);
      stream.input.close();
      for (final back in [
        <String>[],
        ['disabled'],
      ]) {
        await expectLater(
          registry.resolve(
            catalogTrack(duration: duration),
            OnlineQuality.standard,
            preferredSourceId: 'gone',
            fallbackOrder: back,
          ),
          throwsA(isA<OnlineException>()),
        );
      }
      expect(qq.calls, isEmpty);
      expect(opens, ['B']);
    },
  );

  test('QQ throttling or refusal does not invoke checked backups', () async {
    for (final kind in [
      OnlineErrorKind.rateLimited,
      OnlineErrorKind.rejected,
      OnlineErrorKind.authenticationRequired,
    ]) {
      qq.reply = (_, _) async => throw OnlineException(kind);
      await expectLater(
        registry.resolve(
          catalogTrack(duration: duration),
          OnlineQuality.standard,
          fallbackOrder: order,
          cancellation: owner,
        ),
        throwsA(isA<OnlineException>().having((e) => e.kind, 'kind', kind)),
      );
    }
    expect(opens, isEmpty);
    expect(attempts, isEmpty);
  });

  test('short preview is closed before B is played; a validated stream remains readable', () async {
    media['A'] = Uint8List.sublistView(mp3Fixture(), 0, 74 + 417 * 100);
    final stream = await play();
    expect(stream.sourceId, ids['B']);
    expect(opens, ['A', 'B']);
    expect(bodies.first.readers.single.closed, isTrue);
    final input = stream.input as ControlledEncodedInput;
    final reader = await input.openAt(0, PcmCancellation());
    expect((await reader.read(4)).take(2), [255, 251]);
    reader.close();
    input.close();
    expect(qq.calls, isEmpty);
  });
  test('wrong actual bitrate is discarded before downloading B in the original tier', () async {
    final high = media['B'] = _highMp3();
    order = [ids['A']!, ids['A']!, ids['B']!];
    expect(await download(quality: OnlineQuality.high), 'mp3');
    expect(attempts, ['tx/A/320k', 'tx/B/320k']);
    expect(totals, [high.length]);
    expect(saved.takeBytes(), high);
    expect(opens, ['A', 'B']);
    expect(bodies.every((t) => t.readers.single.closed), isTrue);
  });
  test(
    'all responses rejected: no bytes or progress, no lower tier or QQ',
    () async {
      media['A'] = Uint8List.fromList(utf8.encode('<html>not audio</html>'));
      media['B'] = flacFixture();
      await expectLater(
        download(quality: OnlineQuality.high),
        throwsA(isA<OnlineException>()),
      );
      expect(saved.length, 0);
      expect(totals, isEmpty);
      expect(attempts.every((s) => s.endsWith('/320k')), isTrue);
      expect(qq.calls, isEmpty);
    },
  );
  test('all original-platform scripts precede matching a different platform; pins stay exact', () async {
    unavailable.addAll(['tx/A', 'tx/B']);
    media['B'] = flacFixture();
    expect(await manager.selectPlatform(ids['A']!, LxPlatform.tx), isTrue);
    expect(await download(quality: OnlineQuality.lossless), 'flac');
    expect(attempts, ['tx/A/flac', 'tx/B/flac', 'kw/B/flac']);
    expect(catalog.queries, [LxPlatform.kw]);
    expect(opens, ['B']);
  });
  test('unchecked, disabled and duplicate IDs do not produce extra attempts; empty never asks QQ', () async {
    expect(await manager.configure(ids['A']!, enable: false), isTrue);
    order = ['qq', 'gone', ids['A']!, ids['B']!, ids['B']!];
    expect(await download(), 'mp3');
    expect(opens, ['B']);
    order = [];
    await expectLater(play(), throwsA(isA<OnlineException>()));
    expect(attempts, ['tx/B/128k']);
    expect(qq.calls, isEmpty);
  });
  test(
    'missing original duration cannot validate a full song or initiate media',
    () async {
      duration = null;
      await expectLater(play(), throwsA(isA<OnlineException>()));
      expect(opens, isEmpty);
      expect(attempts, isEmpty);
    },
  );
  for (final code in [401, 403, 429]) {
    test(
      'HTTP $code stops rather than rotating credentials or scripts',
      () async {
        status['A'] = code;
        await expectLater(download(), throwsA(isA<OnlineException>()));
        expect(opens, ['A']);
        expect(totals, isEmpty);
      },
    );
  }
  test('certificate refusal cannot rotate the playback source', () async {
    beforeMedia = (_) async =>
        throw const LxRequestException(LxRequestFailure.tls);
    await expectLater(play(), throwsA(isA<LxRequestException>()));
    expect(opens, ['A']);
    expect(qq.calls, isEmpty);
  });
  for (final revoke in [false, true]) {
    test(
      'pending probe is stopped by ${revoke ? 'revocation' : 'cancellation'}',
      () async {
        final entered = Completer<void>();
        beforeMedia = (scope) async {
          entered.complete();
          await scope.until(Completer<void>().future);
        };
        final stopped = expectLater(
          download(),
          throwsA(
            revoke
                ? isA<OnlineException>().having(
                    (e) => e.kind,
                    'kind',
                    OnlineErrorKind.closed,
                  )
                : isA<PcmCancelled>(),
          ),
        );
        await entered.future;
        if (revoke) {
          await manager.configure(ids['A']!, enable: false);
        } else {
          owner.cancel();
        }
        await stopped;
        expect(opens, ['A']);
        expect(totals, isEmpty);
      },
    );
  }
  test(
    'partial body or destination failure never appends a second file',
    () async {
      truncate = true;
      await expectLater(download(), throwsA(isA<OnlineException>()));
      expect(saved.length, greaterThan(0));
      expect(opens, ['A']);
      truncate = false;
      opens.clear();
      await expectLater(
        download(
          write: (_) async =>
              throw const OnlineException(OnlineErrorKind.transport),
        ),
        throwsA(isA<OnlineException>()),
      );
      expect(opens, ['A']);
    },
  );
  test('manual single source does not inherit the ordered scripts', () async {
    unavailable.addAll(['tx/A', 'kw/A']);
    await expectLater(
      download(source: ids['A']!),
      throwsA(isA<OnlineException>()),
    );
    expect(attempts.every((s) => s.contains('/A/')), isTrue);
    expect(opens, isEmpty);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_address_resolver.dart' show LxFetch;
import 'package:motif/online/lx/lx_music_platform.dart';
import 'package:motif/online/lx/lx_native_worker.dart';
import 'package:motif/online/lx/lx_platform_catalog.dart';
import 'package:motif/online/lx/lx_request_error.dart';
import 'package:motif/online/lx/lx_source_manager.dart';
import 'package:motif/online/lx/lx_source_store.dart';

import '../support/lx_catalog_fixture.dart';
import 'playback_fakes.dart';

const _script = '/*\n * @name Offline fixture\n */';
const _url = 'https://media.example.test/audio';

final class _Input extends Fake implements ControlledPcmInput {
  @override
  void close() {}
}

void main() {
  late Directory root;
  late LxSourceManager manager;
  late MusicSourceRegistry registry;
  late LxSourceStore store;
  late FakePlaybackSource qq;
  late CatalogFixture wire;
  late DiagnosticRecorder diagnostics;
  late Map<String, List<String>> declared;
  late List<String> attempts;
  late List<Map> music;
  late int fetches, downloads, opens, probes, apiStatus;
  late bool brokenInit;
  LxFetch? apiReply;
  late Future<Map<String, Object?>> Function(
    String,
    LxRequestHandler,
    PcmCancellation,
  )
  reply;
  late String id;
  final track = catalogTrack();

  void construct() {
    qq = FakePlaybackSource('qq');
    registry = MusicSourceRegistry(qq: qq);
    manager = LxSourceManager(
      store: store,
      registry: registry,
      catalog: LxPlatformCatalog(open: wire.open),
      run:
          (
            bytes, {
            required info,
            event,
            required onRequest,
            required cancellation,
          }) async {
            if (event == null) {
              probes++;
              expect(await onRequest({}, cancellation), {'error': 'denied'});
              if (brokenInit) return {'error': 'init'};
              return {
                'capabilities': {
                  'sources': {
                    for (final e in declared.entries)
                      e.key: {
                        'type': 'music',
                        'actions': ['musicUrl'],
                        'qualitys': e.value,
                      },
                  },
                },
              };
            }
            final platform = event['source'] as String;
            final data = event['info'] as Map;
            expect(data['type'], 'flac');
            expect(event['action'], 'musicUrl');
            final snapshot = data['musicInfo'] as Map;
            expect(snapshot['source'], platform);
            attempts.add(platform);
            music.add(snapshot);
            return reply(platform, onRequest, cancellation);
          },
      fetch: (req, scope) async {
        fetches++;
        if (apiReply case final respond?) return respond(req, scope);
        return {'statusCode': apiStatus, 'body': null};
      },
      open: (uri, _, _) async {
        opens++;
        expect(uri.toString(), _url);
        return _Input();
      },
      download: (uri, _, write, onTotal) async {
        downloads++;
        expect(uri.toString(), _url);
        onTotal(1);
        await write(Uint8List.fromList([1]));
        return 'flac';
      },
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('motif-platform-contract-');
    store = LxSourceStore(() async => root);
    diagnostics = DiagnosticRecorder()..setEnabled(true);
    wire = CatalogFixture();
    declared = {
      for (final p in ['tx', 'kw', 'kg']) p: ['128k', 'flac'],
    };
    attempts = [];
    music = [];
    fetches = downloads = opens = probes = 0;
    apiStatus = 200;
    apiReply = null;
    brokenInit = false;
    reply = (p, _, _) async =>
        p == 'tx' ? {'error': 'unavailable'} : {'url': _url};
    construct();
  });
  tearDown(() async {
    diagnostics.dispose();
    manager.dispose();
    registry.close();
    await root.delete(recursive: true);
  });
  Future<void> install() async {
    expect(await manager.import(utf8.encode(_script)), isTrue);
    id = manager.sources.single.id;
    expect(wire.queries, isEmpty);
    expect(fetches, 0);
  }

  Future<OnlineStream> play({PcmCancellation? cancel, String? fallback}) =>
      registry.resolve(
        track,
        OnlineQuality.lossless,
        cancellation: cancel,
        preferredSourceId: id,
        fallbackSourceId: fallback,
        trace: diagnostics.begin(DiagnosticOperation.playback),
      );
  Future<String> download() => registry.download(
    id,
    track,
    OnlineQuality.lossless,
    cancellation: PcmCancellation(),
    write: (_) async {},
    onTotal: (_) {},
  );
  Future<Map<String, Object?>> request(
    LxRequestHandler send,
    PcmCancellation work,
  ) => send({'url': 'https://api.example.test/song', 'options': {}}, work);

  test('a KG pin bypasses tx and kw and survives restart; auto restores original order', () async {
    await install();
    expect(await manager.selectPlatform(id, LxPlatform.kg), isTrue);
    manager.dispose();
    registry.close();
    construct();
    await manager.initialize();
    expect(manager.sources.single.platform, LxPlatform.kg);
    expect(await download(), 'flac');
    expect(attempts, ['kg']);
    expect(wire.queries, [LxPlatform.kg]);
    expect(await manager.selectPlatform(id, null), isTrue);
    expect(await download(), 'flac');
    expect(attempts, ['kg', 'tx', 'kw']);
  });
  test('pinning QQ is a no-cross-catalog mode including on failures and unsupported tiers', () async {
    declared = {
      'tx': ['128k'],
      'kg': ['flac'],
    };
    await install();
    expect(await manager.selectPlatform(id, LxPlatform.kw), isFalse);
    expect(await manager.selectPlatform(id, LxPlatform.tx), isTrue);
    expect(manager.sources.single.qualities, {OnlineQuality.standard});
    await expectLater(
      download(),
      throwsA(
        isA<OnlineException>().having(
          (e) => e.kind,
          'kind',
          OnlineErrorKind.unsupportedQuality,
        ),
      ),
    );
    // A replacement cannot silently broaden an existing explicit pin.
    declared = {
      'kg': ['flac'],
    };
    expect(
      await manager.import(utf8.encode('$_script replacement'), replaceId: id),
      isFalse,
    );
    expect(manager.sources.single.platform, LxPlatform.tx);
    expect(wire.requests, isEmpty);
    expect(attempts, isEmpty);
  });
  test('tx success starts no platform lookup or backup', () async {
    await install();
    reply = (_, _, _) async => {'url': _url};
    final stream = await play(fallback: 'qq') as ControlledOnlineStream;
    stream.input.close();
    expect(attempts, ['tx']);
    expect(wire.queries, isEmpty);
    expect(qq.calls, isEmpty);
  });
  test('same script plays the KW match at the same tier, keeps QQ and redacts match diagnostics', () async {
    await install();
    final stream = await play(fallback: 'qq') as ControlledOnlineStream;
    expect(stream.requestedQuality, OnlineQuality.lossless);
    expect(stream.sourceId, id);
    expect(stream.uri.scheme, 'motif-controlled');
    stream.input.close();
    expect(track.identity, 'qq:7:originalQQ');
    expect(music.first['songmid'], track.mid);
    expect(music.last['songmid'], '731');
    expect(attempts, ['tx', 'kw']);
    expect(wire.queries, [LxPlatform.kw]);
    expect(qq.calls, isEmpty);
    expect(opens, 1);
    expect(downloads, 0);
    final text = utf8.decode(diagnostics.export({}).bytes);
    expect(text, contains('lxPlatformMatch'));
    expect(text, contains('"platform": "kw"'));
    for (final secret in [
      track.mid,
      track.title,
      track.album,
      id,
      'kuwo.cn',
      _url,
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });
  test('skips an undeclared platform/tier and downloads once from the KG row, never changes scripts', () async {
    declared = {
      'kw': ['128k'],
      'kg': ['flac'],
      'wy': ['flac'],
    };
    await install();
    expect(manager.sources.single.capabilities.byPlatform.keys, [
      LxPlatform.kw,
      LxPlatform.kg,
    ]);
    expect(await download(), 'flac');
    expect(attempts, ['kg']);
    expect(wire.queries, [LxPlatform.kg]);
    expect(music.single['songmid'], 912);
    expect(music.single['hash'], baseHash);
    expect(downloads, 1);
    expect(opens, 0);
    expect(qq.calls, isEmpty);
  });
  test(
    'ambiguous KW never reaches script; uses KG only after matching it',
    () async {
      wire.rows[LxPlatform.kw] = [
        kwRow(),
        kwRow({'MUSICRID': 'MUSIC_733'}),
      ];
      await install();
      expect(await download(), 'flac');
      expect(attempts, ['tx', 'kg']);
      expect(wire.queries, [LxPlatform.kw, LxPlatform.kg]);
    },
  );
  test(
    'eligible channel failure can continue to the next channel, no downgrade',
    () async {
      await install();
      reply = (p, _, _) async =>
          p == 'kg' ? {'url': _url} : {'error': 'unavailable'};
      expect(await download(), 'flac');
      expect(attempts, ['tx', 'kw', 'kg']);
      expect(wire.queries, [LxPlatform.kw, LxPlatform.kg]);
    },
  );
  test(
    'no reliable match leaves playback to the explicitly selected backup only',
    () async {
      wire.rows = {LxPlatform.kw: [], LxPlatform.kg: []};
      await install();
      final stream = await play(fallback: 'qq');
      expect(stream.sourceId, 'qq');
      expect(attempts, ['tx']);
      expect(qq.calls.single, (track, OnlineQuality.lossless));
      expect(opens, 0);
    },
  );
  test('script-wide initialization failure only tries the configured backup, never more platforms', () async {
    await install();
    reply = (_, _, _) async => {'error': 'init'};
    expect((await play(fallback: 'qq')).sourceId, 'qq');
    expect(attempts, ['tx']);
    expect(wire.requests, isEmpty);
  });
  for (final (status, kind) in [
    (429, OnlineErrorKind.rateLimited),
    (403, OnlineErrorKind.rejected),
    (0, OnlineErrorKind.rejected),
  ]) {
    test(
      'parallel peer cannot redirect or hide terminal outcome $status',
      () async {
        await install();
        final lateResponse = Completer<void>();
        apiReply = (request, scope) async {
          if (fetches == 1) {
            await lateResponse.future;
            expect(scope.cancelled, isTrue);
            expect(request.onRedirect!, throwsA(isA<PcmCancelled>()));
            // A transport may finish after its caller cancelled it.
            return {'statusCode': 200};
          }
          if (status == 0) {
            throw const LxRequestException(LxRequestFailure.privateAddress);
          }
          return {'statusCode': status};
        };
        reply = (_, send, work) async {
          final peer = expectLater(
            request(send, work),
            throwsA(isA<PcmCancelled>()),
          );
          await request(send, work);
          expect(await request(send, work), {'error': 'denied'});
          lateResponse.complete();
          await peer;
          return {'url': _url};
        };
        await expectLater(
          play(fallback: 'qq'),
          throwsA(isA<OnlineException>().having((e) => e.kind, 'kind', kind)),
        );
        expect(fetches, 2);
        expect(attempts, ['tx']);
        expect(qq.calls, isEmpty);
        expect(wire.requests, isEmpty);
        expect(opens, 0);
        final events =
            (jsonDecode(utf8.decode(diagnostics.export({}).bytes))
                    as Map)['events']
                as List;
        final starts = events.where((r) => r['event'] == 'lxApiStart');
        expect(starts.map((r) => r['inFlight']), [1, 2]);
        expect(starts.map((r) => r['timeoutMs']), [6000, 6000]);
      },
    );
  }

  for (final secondWins in [true, false]) {
    test(
      'out-of-order callbacks keep newest candidate failure attribution (success: $secondWins)',
      () async {
        declared = {
          'tx': ['flac'],
        };
        await install();
        final release = Completer<void>();
        apiReply = (_, _) async {
          if (fetches == 1) {
            await release.future;
            if (secondWins) {
              throw const LxRequestException(LxRequestFailure.dns);
            }
          } else if (!secondWins) {
            throw const LxRequestException(LxRequestFailure.timeout);
          }
          return {'statusCode': 200};
        };
        reply = (_, send, work) async {
          final first = request(send, work);
          await request(send, work);
          release.complete();
          await first;
          return {'error': 'unavailable'};
        };
        await expectLater(
          play(),
          throwsA(
            secondWins
                ? isA<OnlineException>().having(
                    (e) => e.kind,
                    'kind',
                    OnlineErrorKind.unavailable,
                  )
                : isA<LxRequestException>().having(
                    (e) => e.reason,
                    'reason',
                    LxRequestFailure.timeout,
                  ),
          ),
        );
        expect(fetches, 2);
      },
    );
  }

  test('overlapping redirects spend the same four-hop allowance and cannot reset it by switching', () async {
    await install();
    final both = Completer<void>();
    int hops = 0;
    apiReply = (req, _) async {
      hops++;
      if (fetches == 2) both.complete();
      await both.future;
      req.onRedirect!();
      hops++;
      await Future<void>.delayed(Duration.zero);
      req.onRedirect!();
      hops++;
      return {'statusCode': 200};
    };
    reply = (_, send, work) async {
      Future<void> one() async {
        try {
          await request(send, work);
        } on PcmCancelled {
          /* peer was stopped */
        }
      }

      await Future.wait([one(), one()]);
      return {'url': _url};
    };
    await expectLater(
      play(fallback: 'qq'),
      throwsA(
        isA<LxRequestException>().having(
          (e) => e.reason,
          'reason',
          LxRequestFailure.budget,
        ),
      ),
    );
    expect(hops, 4);
    expect(attempts, ['tx']);
    expect(qq.calls, isEmpty);
    expect(wire.requests, isEmpty);
  });

  for (final (status, kind) in [
    (429, OnlineErrorKind.rateLimited),
    (403, OnlineErrorKind.rejected),
  ]) {
    test(
      'script API $status stops on the original platform even if the script returns a URL',
      () async {
        await install();
        apiStatus = status;
        reply = (_, send, work) async {
          await request(send, work);
          await request(send, work);
          return {'url': _url};
        };
        await expectLater(
          play(fallback: 'qq'),
          throwsA(isA<OnlineException>().having((e) => e.kind, 'kind', kind)),
        );
        expect(fetches, 1);
        expect(wire.requests, isEmpty);
        expect(attempts, ['tx']);
        expect(qq.calls, isEmpty);
        expect(opens, 0);
      },
    );
    test(
      'catalog $status stops without trying the next platform or script',
      () async {
        await install();
        wire.status = status;
        await expectLater(
          play(fallback: 'qq'),
          throwsA(isA<OnlineException>().having((e) => e.kind, 'kind', kind)),
        );
        expect(wire.queries, [LxPlatform.kw]);
        expect(attempts, ['tx']);
        expect(qq.calls, isEmpty);
      },
    );
  }
  test(
    'an invalid media destination is never grounds for a platform switch',
    () async {
      await install();
      reply = (_, _, _) async => {'url': 'http://127.0.0.1/no'};
      await expectLater(
        play(fallback: 'qq'),
        throwsA(
          isA<LxRequestException>().having(
            (e) => e.reason,
            'reason',
            LxRequestFailure.mediaAddress,
          ),
        ),
      );
      expect(attempts, ['tx']);
      expect(qq.calls, isEmpty);
      expect(wire.queries, isEmpty);
    },
  );
  test(
    'four total script API admissions across platforms, not four per channel',
    () async {
      await install();
      reply = (p, send, work) async {
        for (var i = 0; i < 3; i++) {
          await request(send, work);
        }
        return {'error': 'unavailable'};
      };
      await expectLater(
        play(fallback: 'qq'),
        throwsA(
          isA<LxRequestException>().having(
            (e) => e.reason,
            'reason',
            LxRequestFailure.budget,
          ),
        ),
      );
      expect(fetches, 4);
      expect(attempts, ['tx', 'kw']);
      expect(wire.queries, [LxPlatform.kw]);
      expect(qq.calls, isEmpty);
    },
  );
  for (final revoke in [false, true]) {
    test(
      'late catalog response cannot dispatch after ${revoke ? 'revocation' : 'cancellation'}',
      () async {
        await install();
        final started = Completer<void>();
        final gate = Completer<void>();
        final cancel = PcmCancellation();
        wire.beforeResponse = (scope) async {
          started.complete();
          await gate.future;
          expect(scope.cancelled, isTrue);
        };
        final failure = expectLater(
          play(cancel: cancel, fallback: 'qq'),
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
        await started.future;
        if (revoke) {
          expect(await manager.configure(id, enable: false), isTrue);
        } else {
          cancel.cancel();
        }
        gate.complete();
        await failure;
        expect(attempts, ['tx']);
        expect(opens, 0);
        expect(qq.calls, isEmpty);
        expect(wire.bodies.single.closed, isTrue);
      },
    );
  }
  for (final failed in [false, true]) {
    test(
      'old tx-only manifest is probed offline and ${failed ? 'retains tx after probe failure' : 'gains channels without reimport'}',
      () async {
        await install();
        final old = manager.sources.single;
        final json = old.toJson()
          ..remove('platforms')
          ..['qualities'] = ['flac'];
        await File('${root.path}/sources.json').writeAsString(
          jsonEncode({
            'schema': 2,
            'sources': [json],
          }),
        );
        manager.dispose();
        registry.close();
        brokenInit = failed;
        construct();
        await manager.initialize();
        final upgraded = manager.sources.single;
        expect(upgraded.id, old.id);
        expect(upgraded.digest, old.digest);
        expect(upgraded.version, old.version);
        expect(upgraded.enabled, isTrue);
        expect(upgraded.needsProbe, failed);
        expect(probes, 2);
        expect((await store.load()).single.needsProbe, failed);
        expect(wire.queries, isEmpty);
        expect(attempts, isEmpty);
        expect(
          upgraded.capabilities.byPlatform.keys,
          failed ? [LxPlatform.tx] : LxPlatform.values,
        );
      },
    );
  }
}

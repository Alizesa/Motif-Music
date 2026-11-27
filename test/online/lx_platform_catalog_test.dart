import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_music_platform.dart';
import 'package:motif/online/lx/lx_platform_catalog.dart';

import '../support/lx_catalog_fixture.dart';

void main() {
  late CatalogFixture wire;
  late LxPlatformCatalog catalog;
  late DateTime now;
  setUp(() {
    wire = CatalogFixture();
    now = DateTime.utc(2026);
    catalog = LxPlatformCatalog(open: wire.open, now: () => now);
  });
  Future<Map<String, Object?>?> match(
    LxPlatform p, [
    OnlineQuality q = OnlineQuality.lossless,
  ]) async =>
      (await catalog.match(p, catalogTrack(), q, PcmCancellation())).music;

  test('KW builds the anonymous first page and sends native RID, specs and sanitized LX fields', () async {
    wire.rows[LxPlatform.kw] = [
      kwRow({'secret': 'not part of musicInfo', 'url': 'ignored'}),
    ];
    final info = (await match(LxPlatform.kw))!;
    final params = wire.requests.single.queryParameters;
    expect(params['all'], '曲目 甲、乙');
    expect(params['rn'], '8');
    expect(params['pn'], '0');
    expect(info['source'], 'kw');
    expect(info['songmid'], '731');
    expect(info['albumId'], '76');
    expect(info['interval'], '03:01');
    expect(info['singer'], '乙、甲');
    expect(info['types'], [
      {'type': '128k', 'size': '4.2M'},
      {'type': 'flac', 'size': '24.2M'},
    ]);
    expect(info['_types'], {
      '128k': {'size': '4.2M'},
      'flac': {'size': '24.2M'},
    });
    for (final field in ['secret', 'url', 'strMediaMid', 'songId', 'hash']) {
      expect(info.containsKey(field), isFalse);
    }
    expect(wire.bodies.single.closed, isTrue);
  });
  test('KG checks the grouped child itself and keeps base and tier hashes distinct', () async {
    wire.rows[LxPlatform.kg] = [
      kgRow({
        'Suffix': '(Live)',
        'Grp': [kgRow(), kgRow()],
      }),
    ];
    final info = (await match(LxPlatform.kg))!;
    expect(wire.requests.single.queryParameters['keyword'], '曲目 甲、乙');
    expect(wire.requests.single.queryParameters['page'], '1');
    expect(info['songmid'], 912);
    expect(info['hash'], baseHash);
    expect(info['_types'], {
      '128k': {'size': '64.00K', 'hash': baseHash},
      'flac': {'size': '10.00M', 'hash': losslessHash},
    });
    expect(info['interval'], '03:00');
  });
  test('zero-size entry is not an available quality', () async {
    wire.rows[LxPlatform.kw] = [
      kwRow({'N_MINFO': 'level:ff,bitrate:2000,format:flac,size:0.0M'}),
    ];
    final result = await catalog.match(
      LxPlatform.kw,
      catalogTrack(),
      OnlineQuality.lossless,
      PcmCancellation(),
    );
    expect(result.reason, LxMatchReason.missingQuality);
    expect(result.music, isNull);
  });
  for (final (reason, rows) in [
    (
      'different title version',
      [
        kwRow({'SONGNAME': '曲目 (伴奏)'}),
      ],
    ),
    (
      'missing artist',
      [
        kwRow({'ARTIST': '甲'}),
      ],
    ),
    (
      'other album',
      [
        kwRow({'ALBUM': '其它专辑'}),
      ],
    ),
    (
      'missing duration',
      [
        kwRow({'DURATION': '0'}),
      ],
    ),
    (
      'six second difference',
      [
        kwRow({'DURATION': '186'}),
      ],
    ),
    (
      'ambiguous platform identities',
      [
        kwRow(),
        kwRow({'MUSICRID': 'MUSIC_732'}),
      ],
    ),
    (
      'requested tier missing',
      [
        kwRow({'N_MINFO': 'level:mp3,bitrate:128,format:mp3,size:4.2M'}),
      ],
    ),
  ]) {
    test('KW rejects $reason', () async {
      wire.rows[LxPlatform.kw] = rows;
      expect(await match(LxPlatform.kw), isNull);
    });
  }
  test('KG does not substitute a base hash for a missing tier hash', () async {
    wire.rows[LxPlatform.kg] = [
      kgRow({'SQFileHash': ''}),
    ];
    expect(await match(LxPlatform.kg), isNull);
  });
  test(
    'only a unique best album is selected, inclusive five-second boundary',
    () async {
      wire.rows[LxPlatform.kw] = [
        kwRow({'ALBUM': '', 'MUSICRID': '732'}),
        kwRow({'DURATION': 175}),
      ];
      expect((await match(LxPlatform.kw))?['songmid'], '731');
    },
  );
  test('insufficient original metadata sends no queries', () async {
    for (final track in [
      catalogTrack(duration: null),
      catalogTrack(artists: []),
      catalogTrack(title: ''),
    ]) {
      expect(
        (await catalog.match(
          LxPlatform.kw,
          track,
          OnlineQuality.standard,
          PcmCancellation(),
        )).reason,
        LxMatchReason.insufficientMetadata,
      );
    }
    expect(wire.queries, isEmpty);
  });
  test(
    'misses expire, successful matches cache metadata only and are tier scoped',
    () async {
      wire.rows[LxPlatform.kw] = [];
      expect(await match(LxPlatform.kw), isNull);
      wire.rows[LxPlatform.kw] = [kwRow()];
      expect(await match(LxPlatform.kw), isNull);
      now = now.add(const Duration(seconds: 31));
      expect(await match(LxPlatform.kw), isNotNull);
      wire.rows[LxPlatform.kw] = [];
      expect(await match(LxPlatform.kw), isNotNull);
      expect(await match(LxPlatform.kw, OnlineQuality.standard), isNull);
      expect(wire.queries.length, 3);
    },
  );
  test('rate limit is terminal and a repeated lookup does not go to the network during cooldown', () async {
    wire.status = 429;
    final limited = isA<OnlineException>().having(
      (e) => e.kind,
      'kind',
      OnlineErrorKind.rateLimited,
    );
    for (var i = 0; i < 2; i++) {
      await expectLater(match(LxPlatform.kw), throwsA(limited));
    }
    expect(wire.requests.length, 1);
    now = now.add(const Duration(seconds: 31));
    wire.status = 200;
    expect(await match(LxPlatform.kw), isNotNull);
  });
  test(
    'oversized reply and group truncation fail closed and close the body',
    () async {
      wire.headers = {
        'content-length': ['262145'],
      };
      await expectLater(match(LxPlatform.kg), throwsA(isA<OnlineException>()));
      wire.headers = {};
      wire.rows[LxPlatform.kg] = [
        kgRow({'Grp': List.filled(65, kgRow())}),
      ];
      await expectLater(match(LxPlatform.kg), throwsA(isA<OnlineException>()));
      expect(wire.bodies.every((b) => b.closed), isTrue);
    },
  );
}

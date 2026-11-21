import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/features/home/motif_home_page.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/qq/qq_music_client.dart';
import 'package:motif/online/network/qq_http_transport.dart';

import '../online/online_fakes.dart';
import '../online/playback_fakes.dart';
import '../support/library_fixtures.dart';

void main() {
  late FakeLibrarySource source;
  late LibraryController library;
  late FakeQqTransport transport;
  late TestClock clock;
  late QqMusicClient client;
  late FakeAudioEngine engine;

  setUp(() {
    source = FakeLibrarySource();
    library = LibraryController(
      database: LibraryDatabase(NativeDatabase.memory()),
      source: source,
      verifyFile: (_) async {},
    );
    transport = FakeQqTransport()..reply = (_) async => searchResponse();
    clock = TestClock();
    client = testClient(transport, clock);
    engine = FakeAudioEngine();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    client.close();
    await library.close();
    await engine.dispose();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    TextScaler scaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child!,
        ),
        home: MotifHomePage(
          library: library,
          qqMusic: client,
          engineFactory: () => engine,
          preferencesStore: MemoryPlaybackPreferencesStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-search-entry')));
    await tester.pumpAndSettle();
  }

  Future<void> submitQuery(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('qq-search-input')), 'Song');
    await tester.tap(find.byKey(const Key('qq-search-submit')));
    await tester.pump();
  }

  testWidgets('Android shows the bottom Home/My navigation', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpHome(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('个性化歌单'), findsOneWidget);

    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('QQ 音乐账号'), findsOneWidget);
    expect(find.byKey(const Key('my-local-library')), findsOneWidget);
  });

  testWidgets('Windows shows the left Home/My navigation', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await pumpHome(tester);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('QQ search exposes loading and real result states', (
    tester,
  ) async {
    final response = Completer<QqHttpResponse>();
    transport.reply = (_) => response.future;
    await pumpHome(tester);
    await openSearch(tester);
    await submitQuery(tester);

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(transport.requests, hasLength(1));

    response.complete(searchResponse());
    await tester.pumpAndSettle();
    expect(find.text('搜索结果来自 QQ 音乐'), findsNothing);
    expect(find.text('Song'), findsOneWidget);
    expect(find.text('Artist · Album'), findsOneWidget);
  });

  testWidgets('QQ search shows an explicit empty-results state', (
    tester,
  ) async {
    transport.reply = (_) async => searchResponse(tracks: [], total: 0);
    await pumpHome(tester);
    await openSearch(tester);
    await submitQuery(tester);
    await tester.pumpAndSettle();

    expect(find.text('没有找到相关歌曲'), findsOneWidget);
    expect(find.text('试试更换关键词。'), findsOneWidget);
  });

  testWidgets('QQ search maps transport failures to a retryable error', (
    tester,
  ) async {
    transport.reply = (_) async {
      throw const OnlineException(OnlineErrorKind.transport);
    };
    await pumpHome(tester);
    await openSearch(tester);
    await submitQuery(tester);
    await tester.pumpAndSettle();

    expect(find.text('暂时无法完成搜索'), findsOneWidget);
    expect(find.text('网络请求失败，请稍后重试。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('search results only issue QQ song-search requests', (
    tester,
  ) async {
    await pumpHome(tester);
    await openSearch(tester);
    await submitQuery(tester);
    await tester.pumpAndSettle();

    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.jsonBody!.containsKey('SONG'), isTrue);
    expect(transport.requests.single.jsonBody!.containsKey('req_1'), isFalse);
  });
  testWidgets('search selection reaches QQ vkey and the shared mini player', (
    tester,
  ) async {
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
    await pumpHome(tester);
    await openSearch(tester);
    await submitQuery(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qq-track-songMid001')));
    await tester.pumpAndSettle();
    expect(engine.opened.single.uri, 'https://audio.example/M500media001.mp3');
    expect(transport.requests, hasLength(2));
    expect(find.byKey(const Key('catalog-mini-player')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-mini-player')), findsOneWidget);
    expect(engine.disposeCount, 0);
  });

  testWidgets('editing the field does not change the active pagination query', (
    tester,
  ) async {
    transport.reply = (_) async => searchResponse(
      tracks: [songJson(mid: 'songMid${transport.requests.length}')],
      total: 60,
    );
    await pumpHome(tester);
    await openSearch(tester);
    await submitQuery(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('qq-search-input')),
      'Different',
    );
    await tester.tap(find.byKey(const Key('qq-search-next-page')));
    await tester.pumpAndSettle();
    final search = transport.requests.last.jsonBody!['SONG'] as Map;
    expect((search['param'] as Map)['query'], 'Song');
    expect((search['param'] as Map)['page_num'], 2);
  });

  testWidgets('a new submitted query discards the older pending response', (
    tester,
  ) async {
    final old = Completer<QqHttpResponse>();
    transport.reply = (request) {
      final query =
          ((request.jsonBody!['SONG'] as Map)['param'] as Map)['query'];
      if (query == 'Old') return old.future;
      return Future.value(
        searchResponse(
          tracks: [songJson(mid: 'newSong')..['name'] = 'New result'],
        ),
      );
    };
    await pumpHome(tester);
    await openSearch(tester);
    await tester.enterText(find.byKey(const Key('qq-search-input')), 'Old');
    await tester.tap(find.byKey(const Key('qq-search-submit')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('qq-search-input')), 'New');
    await tester.tap(find.byKey(const Key('qq-search-submit')));
    await tester.pump();
    old.complete(
      searchResponse(
        tracks: [songJson(mid: 'oldSong')..['name'] = 'Old result'],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New result'), findsOneWidget);
    expect(find.text('Old result'), findsNothing);
    expect(transport.requests, hasLength(2));
  });

  testWidgets('source management is inside Settings with an unprefixed title', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('音源管理'), findsNothing);
    await tester.tap(find.byKey(const Key('my-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-source-management')));
    await tester.pumpAndSettle();
    expect(find.text('音源管理'), findsOneWidget);
    expect(find.text('LX 音源管理'), findsNothing);
    expect(find.text('优先播放来源'), findsOneWidget);
  });

  testWidgets('narrow large-text navigation and the carousel remain usable', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await pumpHome(tester, scaler: const TextScaler.linear(1.8));
    await tester.drag(
      find.byKey(const Key('home-featured-carousel')),
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('猜你喜欢'), findsOneWidget);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('my-settings')));
    await tester.tap(find.byKey(const Key('my-settings')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('settings-source-management')), findsOneWidget);
  });
}

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/main.dart';

import 'support/library_fixtures.dart';

void main() {
  late FakeLibrarySource source;
  late LibraryController library;
  late FakeAudioEngine engine;
  late int engineCreations;
  late int libraryCreations;

  setUp(() {
    source = FakeLibrarySource()..files = [testAudio(1)];
    library = LibraryController(
      database: LibraryDatabase(NativeDatabase.memory()),
      source: source,
      verifyFile: (_) async {},
    );
    engine = FakeAudioEngine();
    engineCreations = 0;
    libraryCreations = 0;
  });

  void testAppWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await tester.pumpWidget(
          MotifApp(
            engineFactory: () {
              engineCreations++;
              return engine;
            },
            libraryControllerFactory: () {
              libraryCreations++;
              return library;
            },
          ),
        );
        await tester.pumpAndSettle();
        await body(tester);
      } finally {
        // Close in the same fake-async zone used by application callbacks.
        await tester.pumpWidget(const SizedBox.shrink());
        await library.close();
      }
    });
  }

  Future<void> openLibrary(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open-local-library')));
    await tester.pumpAndSettle();
  }

  testAppWidgets(
    'shows the existing player and shares its engine with the library route',
    (tester) async {
      expect(find.text('Motif'), findsOneWidget);
      expect(find.text('播放器引擎验证'), findsOneWidget);
      expect(find.text('选择音频'), findsOneWidget);
      await openLibrary(tester);
      expect(find.text('本地曲库'), findsOneWidget);
      await library.addDirectory();
      await tester.pumpAndSettle();
      await tester.tap(find.text('track-1.flac'));
      await tester.pumpAndSettle();
      expect(find.text('播放器引擎验证'), findsOneWidget);
      expect(engine.opened.single.title, 'track-1.flac');
      expect(engine.opened.single.uri, testAudio(1).location.locator);
      expect(engineCreations, 1);
      expect(libraryCreations, 1);
      expect(engine.disposeCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await library.close();
      expect(engine.disposeCount, 1);
    },
  );

  testAppWidgets('failed playback stays in the library and can be retried', (
    tester,
  ) async {
    await library.addDirectory();
    engine.openError = StateError('decoder failed');
    await openLibrary(tester);
    await tester.tap(find.text('track-1.flac'));
    await tester.pumpAndSettle();
    expect(find.text('本地曲库'), findsOneWidget);
    expect(find.textContaining('decoder failed'), findsOneWidget);
    expect(engine.opened, isEmpty);
    engine.openError = null;
    await tester.tap(find.text('track-1.flac'));
    await tester.pumpAndSettle();
    expect(find.text('播放器引擎验证'), findsOneWidget);
    expect(engine.opened, hasLength(1));
    engine.reportError('播放中解码失败');
    await tester.pumpAndSettle();
    final error = find.byType(SelectableText);
    await tester.scrollUntilVisible(
      error,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.widget<SelectableText>(error).data, '播放中解码失败');
  });

  testAppWidgets('reopening the library retains its database and engine', (
    tester,
  ) async {
    await library.addDirectory();
    final fileId = library.files.single.id;
    await openLibrary(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await library.refresh(), isTrue);
    await openLibrary(tester);
    expect(find.text('track-1.flac'), findsOneWidget);
    expect(library.files.single.id, fileId);
    expect(engineCreations, 1);
    expect(libraryCreations, 1);
    expect(engine.disposeCount, 0);
  });

  testAppWidgets('finishing playback during back navigation keeps the player', (
    tester,
  ) async {
    await library.addDirectory();
    final opening = Completer<void>();
    engine.openWait = opening.future;
    await openLibrary(tester);
    await tester.tap(find.text('track-1.flac'));
    await tester.pump();
    expect(library.isBusy, isTrue);
    await tester.pageBack();
    // The outgoing library is still mounted during its reverse transition.
    await tester.pump();
    opening.complete();
    await tester.pumpAndSettle();
    expect(find.text('播放器引擎验证'), findsOneWidget);
    expect(find.byKey(const Key('open-local-library')), findsOneWidget);
    expect(engine.opened, hasLength(1));
  });

  testAppWidgets('backgrounding keeps the library and exit cancels its scan', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(await library.refresh(), isTrue);
    source.files = List.generate(201, testAudio);
    final blocked = Completer<void>();
    source.beforeBatch = (batch, cancellation) async {
      if (batch == 1) {
        blocked.complete();
        await cancellation.whenCancelled;
      }
    };
    final scanning = library.addDirectory();
    await blocked.future;
    expect(library.indexedFiles, 200);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(await scanning, isFalse);
    expect(await library.refresh(), isFalse);
    expect(engineCreations, 1);
    expect(libraryCreations, 1);
  });
}

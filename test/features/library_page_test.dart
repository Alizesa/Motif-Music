import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/library/library_page.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';

import '../support/library_fixtures.dart';

void main() {
  late FakeLibrarySource source;
  late LibraryController controller;

  setUp(() {
    source = FakeLibrarySource();
    controller = LibraryController(
      database: LibraryDatabase(NativeDatabase.memory()),
      source: source,
      verifyFile: (_) async {},
    );
  });

  void testLibraryWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // Drift's pending futures need the widget test's fake-async zone.
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
      }
    });
  }

  Future<void> showPage(WidgetTester tester) async {
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: LibraryPage(controller: controller, onPlay: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAction(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(controller.isBusy, isFalse);
  }

  testLibraryWidgets('empty library can add, scan and display pending audio', (
    tester,
  ) async {
    source.files = [testAudio(1)];
    await showPage(tester);
    expect(find.text('添加音乐目录后，即可扫描并播放本地音频。'), findsOneWidget);
    await tapAction(tester, find.byKey(const Key('library-add-directory')));
    expect(find.text('测试音乐'), findsOneWidget);
    expect(find.text('track-1.flac'), findsOneWidget);
    expect(find.text('标签与时长待解析'), findsOneWidget);
    expect(find.text('扫描完成，共登记 1 个音频文件。'), findsOneWidget);
  });

  testLibraryWidgets('next and previous buttons replace the bounded page', (
    tester,
  ) async {
    source.files = List.generate(205, testAudio);
    await controller.initialize();
    await controller.addDirectory();
    await showPage(tester);
    expect(find.text('track-0.flac'), findsOneWidget);
    await tapAction(tester, find.byKey(const Key('library-next-page')));
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('track-100.flac'), findsOneWidget);
    expect(find.text('track-0.flac'), findsNothing);
    expect(controller.files, hasLength(100));
    await tapAction(tester, find.byKey(const Key('library-next-page')));
    expect(find.text('第 3 页'), findsOneWidget);
    expect(controller.files, hasLength(5));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('library-next-page')))
          .onPressed,
      isNull,
    );
    await tapAction(tester, find.byKey(const Key('library-previous-page')));
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('track-100.flac'), findsOneWidget);
  });

  testLibraryWidgets(
    'directory rescan updates files and shows partial failure',
    (tester) async {
      source.files = [testAudio(1), testAudio(2)];
      await controller.initialize();
      await controller.addDirectory();
      await showPage(tester);
      source.files = [testAudio(2), testAudio(3)];
      await tapAction(tester, find.byTooltip('重新扫描 测试音乐'));
      expect(find.text('track-1.flac'), findsNothing);
      expect(find.text('track-2.flac'), findsOneWidget);
      expect(find.text('track-3.flac'), findsOneWidget);
      source.files = [testAudio(4)];
      source.traversalError = const LibraryTraversalException('子目录暂时不可读');
      await tapAction(tester, find.byTooltip('重新扫描 测试音乐'));
      expect(find.text('扫描失败，可重试；原有记录保留'), findsOneWidget);
      expect(find.textContaining('扫描失败：子目录暂时不可读'), findsOneWidget);
      expect(controller.files.map((file) => file.fileName), [
        'track-2.flac',
        'track-3.flac',
        'track-4.flac',
      ]);
      expect(source.scanCalls, 3);
    },
  );

  testLibraryWidgets(
    'list refresh resets pagination without rescanning files',
    (tester) async {
      source.files = List.generate(101, testAudio);
      await controller.initialize();
      await controller.addDirectory();
      await controller.nextPage();
      await showPage(tester);
      expect(find.text('第 2 页'), findsOneWidget);
      await tapAction(tester, find.byTooltip('刷新列表'));
      expect(find.text('第 1 页'), findsOneWidget);
      expect(find.text('track-0.flac'), findsOneWidget);
      expect(source.scanCalls, 1);
    },
  );
  testLibraryWidgets('remove confirmation can be declined then confirmed', (
    tester,
  ) async {
    source.files = [testAudio(1)];
    await controller.initialize();
    await controller.addDirectory();
    await showPage(tester);
    await tester.tap(find.byTooltip('移除 测试音乐'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.directories, hasLength(1));
    expect(source.released, isEmpty);
    await tester.tap(find.byTooltip('移除 测试音乐'));
    await tester.pumpAndSettle();
    await tapAction(tester, find.widgetWithText(FilledButton, '移除'));
    expect(controller.directories, isEmpty);
    expect(find.text('track-1.flac'), findsNothing);
    expect(source.released, hasLength(1));
  });

  testLibraryWidgets(
    'cancel action shows interrupted status and keeps saved audio',
    (tester) async {
      source.files = List.generate(201, testAudio);
      final blocked = Completer<void>();
      source.beforeBatch = (batch, cancellation) async {
        if (batch == 1) {
          blocked.complete();
          await cancellation.whenCancelled;
        }
      };
      await showPage(tester);
      final scanning = controller.addDirectory();
      await blocked.future;
      await tester.pump();
      expect(find.text('正在扫描，已登记 200 个文件'), findsOneWidget);
      await tapAction(tester, find.text('取消扫描'));
      expect(await scanning, isFalse);
      expect(find.text('扫描已中断，可重新扫描'), findsOneWidget);
      expect(find.text('扫描已取消，已登记的曲目和原有记录保留。'), findsOneWidget);
      expect(controller.files, hasLength(100));
    },
  );

  testLibraryWidgets(
    'revoked permission has an explicit recovery instruction',
    (tester) async {
      source.files = [testAudio(1)];
      await controller.initialize();
      await controller.addDirectory();
      source.files = [];
      source.traversalError = const LibraryTraversalException(
        '已撤销授权',
        rootAccessRevoked: true,
      );
      await controller.scanDirectory(controller.directories.single.id);
      await showPage(tester);
      expect(find.text('访问已失效，请再次添加同一目录恢复授权'), findsOneWidget);
      expect(find.textContaining('扫描失败：已撤销授权'), findsOneWidget);
      expect(find.text('track-1.flac'), findsNothing);
      final rootId = controller.directories.single.id;
      source.traversalError = null;
      source.files = [testAudio(1)];
      await tapAction(tester, find.byKey(const Key('library-add-directory')));
      expect(controller.directories.single.id, rootId);
      expect(find.text('track-1.flac'), findsOneWidget);
      expect(find.text('访问已失效，请再次添加同一目录恢复授权'), findsNothing);
    },
  );

  testLibraryWidgets(
    '320px layout tolerates long directory and filename text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      source.picked = PickedLibraryDirectory(
        location: testDirectory.location,
        displayName: '这是一个非常长的音乐目录名称，用于验证手机窄屏显示',
      );
      const longName = '这是一首文件名称非常长的音乐文件，用于验证手机窄屏显示不会溢出.flac';
      final file = testAudio(1);
      source.files = [
        ObservedAudioFile(
          location: file.location,
          fileName: longName,
          sizeBytes: file.sizeBytes,
          modifiedMs: file.modifiedMs,
        ),
      ];
      await controller.initialize();
      await controller.addDirectory();
      await showPage(tester);
      expect(find.text('上一页'), findsOneWidget);
      expect(find.text('下一页'), findsOneWidget);
      expect(find.text(longName), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

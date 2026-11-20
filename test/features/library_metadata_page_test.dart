import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/library/library_page.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/domain/library_models.dart';

import '../support/library_fixtures.dart';

void main() {
  testWidgets(
    'library shows parsed title, artist, album, duration and filename fallback',
    (tester) async {
      final source = FakeLibrarySource()..files = [testAudio(1), testAudio(2)];
      final reader = FakeMetadataReader(
        (file) async => file.id == 1
            ? const TrackMetadata(
                title: '歌曲标题',
                artist: '歌手名称',
                album: '专辑名称',
                durationMs: 123456,
              )
            : const TrackMetadata(),
      );
      final controller = LibraryController(
        database: LibraryDatabase(NativeDatabase.memory()),
        source: source,
        metadataReader: reader,
      );
      try {
        await controller.initialize();
        await controller.addDirectory();
        await controller.startMetadata();
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryPage(controller: controller, onPlay: (_) async {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('歌曲标题'), findsOneWidget);
        expect(find.textContaining('歌手名称 · 专辑名称 · 2:03'), findsOneWidget);
        expect(find.text('track-2.flac'), findsOneWidget);
        expect(find.text('未知歌手 · 未知专辑 · 时长未知'), findsOneWidget);
        expect(
          find.byKey(const Key('library-resume-metadata')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('library-retry-metadata')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
      }
    },
  );

  testWidgets(
    'metadata can be cancelled on a narrow screen while playback stays enabled',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = FakeLibrarySource()..files = [testAudio(1)];
      final gate = Completer<TrackMetadata>();
      final reader = FakeMetadataReader((_) => gate.future);
      final controller = LibraryController(
        database: LibraryDatabase(NativeDatabase.memory()),
        source: source,
        metadataReader: reader,
      );
      try {
        await controller.initialize();
        await controller.addDirectory();
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryPage(controller: controller, onPlay: (_) async {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.isReadingMetadata, isTrue);
        final tile = tester.widget<ListTile>(
          find.byKey(const Key('library-file-1')),
        );
        expect(tile.enabled, isTrue);
        await tester.tap(find.byKey(const Key('library-cancel-metadata')));
        await tester.pumpAndSettle();
        expect(find.text('正在停止读取…'), findsOneWidget);
        gate.complete(const TrackMetadata(title: 'Must not display'));
        await tester.pumpAndSettle();
        expect(find.text('Must not display'), findsNothing);
        expect(find.text('标签与时长待解析'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete(const TrackMetadata());
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
      }
    },
  );
}

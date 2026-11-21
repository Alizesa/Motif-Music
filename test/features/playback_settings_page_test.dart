import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/settings/playback_settings_page.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/settings/playback_quality_repository.dart';
import 'package:motif/settings/playback_quality_settings.dart';

class FailingSettingsRepository extends PlaybackQualitySettingsRepository {
  FailingSettingsRepository(super.database);

  bool failLoad = false;
  bool failSave = false;
  Completer<void>? saving;

  @override
  Future<PlaybackQualityMode> loadMode() async {
    if (failLoad) throw StateError('read failed');
    return super.loadMode();
  }

  @override
  Future<void> saveMode(PlaybackQualityMode mode) async {
    if (failSave) throw StateError('write failed');
    await saving?.future;
    return super.saveMode(mode);
  }
}

void main() {
  late LibraryDatabase database;
  late FailingSettingsRepository repository;

  setUp(() {
    database = LibraryDatabase(NativeDatabase.memory());
    repository = FailingSettingsRepository(database);
  });
  tearDown(() => database.close());

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: PlaybackSettingsPage(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
  }

  RadioListTile<PlaybackQualityMode> tile(WidgetTester tester, String name) =>
      tester.widget(find.byKey(ValueKey('quality-$name')));

  testWidgets(
    'full size rows select via subtitle and persist after reopening',
    (tester) async {
      await open(tester);
      expect(tile(tester, 'followOnline').selected, isTrue);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('quality-highestLocal')))
            .height,
        greaterThanOrEqualTo(80),
      );
      await tester.tap(find.text('优先选择能够确认音质最高的本地版本。'));
      await tester.pumpAndSettle();
      expect(tile(tester, 'highestLocal').selected, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester);
      expect(tile(tester, 'highestLocal').selected, isTrue);
    },
  );

  testWidgets(
    'read error has retry and write error preserves saved selection',
    (tester) async {
      repository.failLoad = true;
      await open(tester);
      expect(find.text('无法读取播放设置，请重试。'), findsOneWidget);
      repository.failLoad = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(tile(tester, 'followOnline').selected, isTrue);
      repository.failSave = true;
      await tester.tap(find.text('本地最高音质'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重新选择。'), findsOneWidget);
      expect(tile(tester, 'followOnline').selected, isTrue);
      repository.failSave = false;
      await tester.tap(find.text('本地最高音质'));
      await tester.pumpAndSettle();
      expect(tile(tester, 'highestLocal').selected, isTrue);
    },
  );

  testWidgets(
    'pending save disables changes and finishing after route disposal is safe',
    (tester) async {
      await open(tester);
      repository.saving = Completer<void>();
      await tester.tap(find.text('本地最高音质'));
      await tester.pump();
      expect(tile(tester, 'followOnline').enabled, isFalse);
      expect(tile(tester, 'highestLocal').enabled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      repository.saving!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await open(tester);
      expect(tile(tester, 'highestLocal').selected, isTrue);
    },
  );

  testWidgets(
    'narrow Android sized viewport supports large text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, scale: 1.6);
      await tester.ensureVisible(find.text('本地最高音质'));
      await tester.tap(find.text('本地最高音质'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tile(tester, 'highestLocal').selected, isTrue);
    },
  );
}

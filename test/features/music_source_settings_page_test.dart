import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/settings/music_source_settings_page.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/lx/lx_source_manager.dart';
import 'package:motif/online/lx/lx_source_store.dart';
import 'package:motif/settings/online_playback_preferences.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import '../online/playback_fakes.dart';
import '../support/ordered_script_stub.dart';

import 'package:motif/online/lx/lx_ordered_source.dart';

Future<void> _choosePrimary(WidgetTester t, String id) async {
  await t.tap(find.byKey(const ValueKey('primary-source')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey('primary-option-$id')).hitTestable().last);
  await t.pumpAndSettle();
}

Future<void> _move(
  WidgetTester t,
  String from,
  String to,
  PointerDeviceKind kind,
) async {
  final grip = find.byKey(ValueKey('drag-$from'));
  final start = t.getCenter(grip);
  final end = t.getCenter(find.byKey(ValueKey('drag-$to')));
  final gesture = await t.startGesture(start, kind: kind);
  // Cross each row's insertion gap with real pointer updates. Jumping past
  // the target in one frame can land after it rather than before it.
  for (var i = 1; i <= 16; i++) {
    await gesture.moveTo(Offset.lerp(start, end, i / 16)!);
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
  await gesture.up();
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'check backups directly and reorder using the handle with touch and mouse',
    (t) async {
      final store = MemoryPlaybackPreferencesStore();
      final settings = OnlinePlaybackSettingsController(store);
      final sources = MusicSourceRegistry(qq: FakePlaybackSource('qq'));
      for (final id in ['A', 'B', 'C']) {
        sources.registerManaged(
          MusicSourceRegistration(name: id, resolver: OrderedScriptStub(id)),
        );
      }
      await t.pumpWidget(
        MaterialApp(
          home: MusicSourceSettingsPage(settings: settings, sources: sources),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('换源顺序'), findsNothing);
      expect(find.text('按顺序换源'), findsNothing);
      expect(find.byKey(const ValueKey('backup-qq')), findsNothing);
      for (final id in ['A', 'B', 'C']) {
        await t.tap(find.byKey(ValueKey('backup-$id')));
        await t.pumpAndSettle();
      }
      expect(store.value.fallbackOrder, ['A', 'B', 'C']);
      expect(store.value.preferredSourceId, 'qq');
      await _move(t, 'C', 'A', PointerDeviceKind.touch);
      expect(store.value.fallbackOrder, ['C', 'A', 'B']);
      await _move(t, 'C', 'B', PointerDeviceKind.mouse);
      expect(store.value.fallbackOrder, ['A', 'B', 'C']);
      await _choosePrimary(t, 'B');
      expect(store.value.fallbackOrder, ['A', 'C']);
      expect(find.byKey(const ValueKey('backup-B')), findsNothing);
      for (final id in ['A', 'C']) {
        await t.tap(find.byKey(ValueKey('backup-$id')));
        await t.pumpAndSettle();
      }
      expect(store.value.fallbackOrder, isEmpty);
      expect(store.value.preferredSourceId, 'B');
      await t.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      sources.close();
    },
  );

  testWidgets(
    'old ordered choice is displayed without a write; failed drag restores saved order',
    (t) async {
      final store = MemoryPlaybackPreferencesStore()
        ..value = const OnlinePlaybackPreferences(
          preferredSourceId: lxOrderedSourceId,
          scriptOrder: ['C', 'B', 'A'],
          fallbackSourceId: 'qq',
        );
      final settings = OnlinePlaybackSettingsController(store);
      final sources = MusicSourceRegistry(qq: FakePlaybackSource('qq'));
      for (final id in ['A', 'B', 'C']) {
        sources.registerManaged(
          MusicSourceRegistration(name: id, resolver: OrderedScriptStub(id)),
        );
      }
      await t.pumpWidget(
        MaterialApp(
          home: MusicSourceSettingsPage(settings: settings, sources: sources),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('primary-source')),
            )
            .value,
        'C',
      );
      expect(
        t
            .widget<CheckboxListTile>(find.byKey(const ValueKey('backup-qq')))
            .value,
        false,
      );
      expect(store.saves, 0);
      store.saveError = StateError('full');
      await _move(t, 'A', 'B', PointerDeviceKind.touch);
      expect(find.text('保存失败，请重试。'), findsOneWidget);
      expect(store.value.scriptOrder, ['C', 'B', 'A']);
      expect(
        t.getCenter(find.byKey(const ValueKey('drag-B'))).dy,
        lessThan(t.getCenter(find.byKey(const ValueKey('drag-A'))).dy),
      );
      await t.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      sources.close();
    },
  );

  testWidgets(
    'an imported source is selectable immediately without a domain form',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('motif-source-ui-'),
      ))!;
      final store = MemoryPlaybackPreferencesStore();
      final settings = OnlinePlaybackSettingsController(store);
      final sources = MusicSourceRegistry(qq: FakePlaybackSource('qq'));
      final managed = LxSourceManager(
        store: LxSourceStore(() async => root),
        registry: sources,
        run:
            (
              _, {
              required info,
              event,
              required onRequest,
              required cancellation,
            }) async => {
              'capabilities': {
                'sources': {
                  'kg': {
                    'type': 'music',
                    'actions': ['musicUrl'],
                    'qualitys': ['flac'],
                  },
                  'tx': {
                    'type': 'music',
                    'actions': ['musicUrl'],
                    'qualitys': ['128k'],
                  },
                },
              },
            },
      );
      try {
        expect(
          await tester.runAsync(
            () => managed.import(utf8.encode('/*! @name Ready source */')),
          ),
          isTrue,
        );
        expect(managed.sources.single.enabled, isTrue);
        await tester.pumpWidget(
          MaterialApp(
            home: MusicSourceSettingsPage(
              sources: sources,
              settings: settings,
              managed: managed,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final id = managed.sources.single.id;
        await _choosePrimary(tester, id);
        await tester.pumpAndSettle();
        expect(store.value.preferredSourceId, id);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('域名授权'), findsNothing);
        final channel = find.byKey(ValueKey('platform-$id'));
        expect(channel, findsNothing);
        await tester.tap(find.byKey(const PageStorageKey('manage-scripts')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          channel,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final select = tester.widget<DropdownButton<String>>(channel);
        expect(select.items!.map((item) => item.value), ['auto', 'tx', 'kg']);
        // The menu callback commits a real file: invoke it on the real async
        // clock, not from a route animation waiting for the next fake frame.
        await tester.runAsync(() async {
          final saved = Completer<void>();
          void onChanged() {
            if (!managed.busy && !saved.isCompleted) saved.complete();
          }

          managed.addListener(onChanged);
          try {
            select.onChanged!('kg');
            await saved.future.timeout(const Duration(seconds: 4));
          } finally {
            managed.removeListener(onChanged);
          }
        });
        await tester.pumpAndSettle();
        expect(tester.widget<DropdownButton<String>>(channel).value, 'kg');
        expect(managed.sources.single.platform?.name, 'kg');
        expect(store.value.preferredSourceId, id);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        managed.dispose();
        settings.dispose();
        sources.close();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets('registered sources can be selected as primary and fallback', (
    tester,
  ) async {
    final store = MemoryPlaybackPreferencesStore();
    final settings = OnlinePlaybackSettingsController(store);
    final sources = MusicSourceRegistry(
      qq: FakePlaybackSource('qq'),
      thirdPartySources: [
        MusicSourceRegistration(
          name: 'Custom',
          resolver: FakePlaybackSource('custom'),
        ),
      ],
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: MusicSourceSettingsPage(sources: sources, settings: settings),
        ),
      );
      await tester.pumpAndSettle();
      await _choosePrimary(tester, 'custom');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('backup-qq')));
      await tester.tap(find.byKey(const ValueKey('backup-qq')));
      await tester.pumpAndSettle();
      expect(store.value.preferredSourceId, 'custom');
      expect(store.value.fallbackOrder, ['qq']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      sources.close();
    }
  });

  testWidgets('failed source saves keep the previously selected primary', (
    tester,
  ) async {
    final store = MemoryPlaybackPreferencesStore()
      ..saveError = StateError('write failed');
    final settings = OnlinePlaybackSettingsController(store);
    final sources = MusicSourceRegistry(
      qq: FakePlaybackSource('qq'),
      thirdPartySources: [
        MusicSourceRegistration(
          name: 'Custom',
          resolver: FakePlaybackSource('custom'),
        ),
      ],
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: MusicSourceSettingsPage(sources: sources, settings: settings),
        ),
      );
      await tester.pumpAndSettle();
      await _choosePrimary(tester, 'custom');
      await tester.pumpAndSettle();
      expect(settings.value.preferredSourceId, 'qq');
      expect(find.text('保存失败，请重试。'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      sources.close();
    }
  });
}

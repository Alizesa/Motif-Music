import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/settings/music_source_settings_page.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/lx/lx_source_manager.dart';
import 'package:motif/online/lx/lx_source_store.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import '../online/playback_fakes.dart';
import '../support/ordered_script_stub.dart';

import 'package:motif/online/lx/lx_ordered_source.dart';

void main() {
  testWidgets(
    'scripts must be checked and can be reordered before selecting ordered playback',
    (t) async {
      final store = MemoryPlaybackPreferencesStore();
      final settings = OnlinePlaybackSettingsController(store);
      final sources = MusicSourceRegistry(qq: FakePlaybackSource('qq'));
      for (final id in ['A', 'B']) {
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
      Future<void> tap(String key) async {
        final f = find.byKey(ValueKey(key));
        // Lazy list entries may exist in the cache above the viewport after
        // reordering. Use real scroll gestures until the actual tile is hittable.
        for (var i = 0; i < 12 && f.hitTestable().evaluate().isEmpty; i++) {
          await t.drag(
            find.byType(ListView),
            Offset(0, key == 'preferred-ordered' ? 200 : -175),
          );
          await t.pumpAndSettle();
        }
        expect(f.hitTestable(), findsOneWidget);
        await t.tap(f.hitTestable());
        await t.pumpAndSettle();
      }

      expect(store.value.scriptOrder, isEmpty);
      expect(
        t
            .widget<RadioListTile<String>>(
              find.byKey(const ValueKey('preferred-ordered')),
            )
            .enabled,
        isFalse,
      );
      await tap('order-A');
      await tap('order-B');
      expect(store.value.scriptOrder, ['A', 'B']);
      await tap('order-up-B');
      expect(store.value.scriptOrder, ['B', 'A']);
      await tap('preferred-ordered');
      expect(store.value.preferredSourceId, lxOrderedSourceId);
      await tap('order-B');
      expect(store.value.scriptOrder, ['A']);
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
        await tester.tap(find.byKey(ValueKey('preferred-$id')));
        await tester.pumpAndSettle();
        expect(store.value.preferredSourceId, id);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('域名授权'), findsNothing);
        final channel = find.byKey(ValueKey('platform-$id'));
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
      await tester.tap(find.byKey(const ValueKey('preferred-custom')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('fallback-qq')));
      await tester.tap(find.byKey(const ValueKey('fallback-qq')));
      await tester.pumpAndSettle();
      expect(store.value.preferredSourceId, 'custom');
      expect(store.value.fallbackSourceId, 'qq');
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
      await tester.tap(find.byKey(const ValueKey('preferred-custom')));
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

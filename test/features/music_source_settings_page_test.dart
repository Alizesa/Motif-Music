import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/settings/music_source_settings_page.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import '../online/playback_fakes.dart';

void main() {
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

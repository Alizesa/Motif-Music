import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/settings/online_playback_preferences.dart';
import 'package:motif/settings/online_playback_settings_controller.dart';

import 'playback_fakes.dart';

void main() {
  test('failed preference loading can be retried', () async {
    final store = MemoryPlaybackPreferencesStore()
      ..loadError = StateError('read failed');
    final settings = OnlinePlaybackSettingsController(store);
    addTearDown(settings.dispose);
    await settings.initialize();
    expect(settings.isReady, isFalse);
    expect(settings.isLoading, isFalse);
    store.loadError = null;
    await settings.initialize();
    expect(settings.isReady, isTrue);
    expect(settings.error, isNull);
  });

  test('failed save keeps the previously persisted selection', () async {
    final store = MemoryPlaybackPreferencesStore();
    final settings = OnlinePlaybackSettingsController(store);
    addTearDown(settings.dispose);
    await settings.initialize();
    store.saveError = StateError('write failed');
    expect(
      await settings.save(
        const OnlinePlaybackPreferences(quality: OnlineQuality.high),
      ),
      isFalse,
    );
    expect(settings.value.quality, OnlineQuality.standard);
    expect(settings.error, isNotNull);
  });

  test(
    'pending saves serialize user choices and do not publish early',
    () async {
      final pending = Completer<void>();
      final store = MemoryPlaybackPreferencesStore()..saveWait = pending.future;
      final settings = OnlinePlaybackSettingsController(store);
      addTearDown(settings.dispose);
      await settings.initialize();
      final saving = settings.save(
        const OnlinePlaybackPreferences(quality: OnlineQuality.high),
      );
      expect(settings.value.quality, OnlineQuality.standard);
      expect(
        await settings.save(
          const OnlinePlaybackPreferences(quality: OnlineQuality.lossless),
        ),
        isFalse,
      );
      expect(store.saves, 1);
      pending.complete();
      expect(await saving, isTrue);
      expect(settings.value.quality, OnlineQuality.high);
    },
  );

  test('a save finishing after disposal does not publish new state', () async {
    final pending = Completer<void>();
    final store = MemoryPlaybackPreferencesStore()..saveWait = pending.future;
    final settings = OnlinePlaybackSettingsController(store);
    await settings.initialize();
    var changes = 0;
    settings.addListener(() => changes++);
    final saving = settings.save(
      const OnlinePlaybackPreferences(quality: OnlineQuality.high),
    );
    final beforeDispose = changes;
    settings.dispose();
    pending.complete();
    expect(await saving, isFalse);
    expect(changes, beforeDispose);
  });
}

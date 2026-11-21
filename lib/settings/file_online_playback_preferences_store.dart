import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'online_playback_preferences.dart';

/// Non-secret playback preferences; account credentials do not enter this file.
class FileOnlinePlaybackPreferencesStore
    implements OnlinePlaybackPreferencesStore {
  FileOnlinePlaybackPreferencesStore({required this.file});

  final Future<File> Function() file;
  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<OnlinePlaybackPreferences> load() => _serial(() async {
    final target = await file();
    if (!await target.exists()) return const OnlinePlaybackPreferences();
    if (await target.length() > 16 * 1024) {
      throw const FormatException('Oversized preferences');
    }
    final json = jsonDecode(await target.readAsString());
    if (json is! Map<String, Object?>) {
      throw const FormatException('Invalid preferences');
    }
    return OnlinePlaybackPreferences.fromJson(json);
  });

  @override
  Future<void> save(OnlinePlaybackPreferences preferences) => _serial(() async {
    final target = await file();
    await target.parent.create(recursive: true);
    final suffix = Random.secure().nextInt(0x7fffffff);
    final temporary = File('${target.path}.$suffix.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode(preferences.toJson()),
        flush: true,
      );
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
}

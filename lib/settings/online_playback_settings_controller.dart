import 'package:flutter/foundation.dart';

import 'online_playback_preferences.dart';

class OnlinePlaybackSettingsController extends ChangeNotifier {
  OnlinePlaybackSettingsController(this.store);
  final OnlinePlaybackPreferencesStore store;

  OnlinePlaybackPreferences _value = const OnlinePlaybackPreferences();
  Future<void>? _loading;
  bool _ready = false;
  bool _saving = false;
  bool _closed = false;
  String? _error;

  OnlinePlaybackPreferences get value => _value;
  bool get isReady => _ready;
  bool get isLoading => _loading != null;
  bool get isSaving => _saving;
  String? get error => _error;

  Future<void> initialize() {
    if (_closed || _ready) return Future.value();
    return _loading ??= Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final value = await store.load();
      if (!_closed) {
        _value = value;
        _ready = true;
        _error = null;
      }
    } catch (_) {
      if (!_closed) _error = '无法读取播放偏好，请重试。';
    } finally {
      _loading = null;
      if (!_closed) notifyListeners();
    }
  }

  Future<bool> save(OnlinePlaybackPreferences value) async {
    if (_closed || !_ready || _saving) return false;
    _saving = true;
    _error = null;
    notifyListeners();
    try {
      await store.save(value);
      if (_closed) return false;
      _value = value;
      return true;
    } catch (_) {
      if (!_closed) _error = '保存失败，请重试。';
      return false;
    } finally {
      _saving = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

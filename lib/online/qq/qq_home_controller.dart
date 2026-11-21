import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/online_error.dart';
import 'auth/qq_session_manager.dart';
import 'qq_account_api.dart';
import 'qq_home_models.dart';
import 'qq_track.dart';

class QqHomeController extends ChangeNotifier {
  QqHomeController({required this.sessions, required this.api}) {
    _epoch = sessions.epoch;
    _subscription = sessions.changes.listen((_) {
      if (_epoch != sessions.epoch || sessions.account == null) {
        _epoch = sessions.epoch;
        _generation++;
        _refreshing = null;
        _daily = const [];
        _feed = null;
        _playlists = const [];
        _recent = const [];
        _loading.clear();
        _errors.clear();
      }
      _notify();
      if (sessions.account != null) unawaited(refresh());
    });
  }
  final QqSessionManager sessions;
  final QqAccountApi api;
  late final StreamSubscription<QqSessionStatus> _subscription;
  late int _epoch;
  int _generation = 0;
  bool _closed = false;
  Future<void>? _refreshing;
  List<QqTrack> _daily = const [];
  QqHomeFeed? _feed;
  List<QqPlaylist> _playlists = const [];
  List<QqPlaylist> _recent = const [];
  final _loading = <String>{};
  final _errors = <String, String>{};

  List<QqTrack> get daily => _daily;
  QqHomeFeed? get feed => _feed;
  List<QqPlaylist> get playlists => _playlists;
  List<QqPlaylist> get recent => _recent;
  bool loading(String section) => _loading.contains(section);
  String? error(String section) => _errors[section];

  Future<void> initialize() async {
    await sessions.initialize();
    if (!_closed && sessions.account != null) await refresh();
  }

  Future<void> refresh() {
    if (_closed || sessions.account == null) return Future.value();
    return _refreshing ??= Future<void>.microtask(_refresh);
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    await Future.wait([
      _load('daily', generation, api.daily, (value) => _daily = value),
      _load('feed', generation, api.homeFeed, (value) => _feed = value),
      _load(
        'playlists',
        generation,
        api.personalizedPlaylists,
        (value) => _playlists = value,
      ),
      _load(
        'recent',
        generation,
        api.recentPlaylists,
        (value) => _recent = value,
      ),
    ]);
    if (generation == _generation) _refreshing = null;
  }

  Future<void> retry(String section) async {
    if (_closed || sessions.account == null || _loading.contains(section)) {
      return;
    }
    final generation = _generation;
    switch (section) {
      case 'daily':
        await _load(section, generation, api.daily, (value) => _daily = value);
      case 'feed':
        await _load(
          section,
          generation,
          api.homeFeed,
          (value) => _feed = value,
        );
      case 'playlists':
        await _load(
          section,
          generation,
          api.personalizedPlaylists,
          (value) => _playlists = value,
        );
      case 'recent':
        await _load(
          section,
          generation,
          api.recentPlaylists,
          (value) => _recent = value,
        );
    }
  }

  Future<void> moreFeed() async {
    if (_closed ||
        _feed == null ||
        !_feed!.hasMore ||
        _loading.contains('feed')) {
      return;
    }
    final previous = _feed!;
    await _load(
      'feed',
      _generation,
      () => api.homeFeed(previous: previous),
      (value) => _feed = value,
    );
  }

  Future<void> _load<T>(
    String section,
    int generation,
    Future<T> Function() work,
    void Function(T) commit,
  ) async {
    _loading.add(section);
    _errors.remove(section);
    _notify();
    try {
      final value = await work();
      if (!_closed && generation == _generation) commit(value);
    } catch (error) {
      if (!_closed && generation == _generation) {
        _errors[section] = error is OnlineException
            ? error.toString()
            : '推荐获取失败，请重试。';
      }
    } finally {
      if (!_closed && generation == _generation) {
        _loading.remove(section);
        _notify();
      }
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _generation++;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

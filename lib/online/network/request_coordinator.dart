import 'dart:async';
import 'dart:collection';

import '../domain/online_error.dart';

/// One instance is shared by a source's search, detail and playback operations.
/// Cache hits and in-flight joins never consume a network slot. No auto-retry.
class RequestCoordinator {
  RequestCoordinator({
    this.minimumInterval = const Duration(milliseconds: 1500),
    this.negativeTtl = const Duration(seconds: 30),
    this.maxCacheEntries = 128,
    this.maxPendingRequests = 24,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
  }) : _now = now ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed {
    if (minimumInterval.isNegative ||
        negativeTtl.isNegative ||
        maxCacheEntries < 1 ||
        maxPendingRequests < 1) {
      throw ArgumentError('Invalid request limits');
    }
  }

  final Duration minimumInterval;
  final Duration negativeTtl;
  final int maxCacheEntries;
  final int maxPendingRequests;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  final _cache = <String, _Cached>{};
  final _pending = <String, _Request>{};
  final _queue = Queue<_Request>();
  bool _draining = false;
  bool _closed = false;
  int _rejections = 0;
  int _generation = 0;
  DateTime? _lastStarted;
  DateTime? _blockedUntil;
  OnlineErrorKind _blockKind = OnlineErrorKind.rateLimited;

  Future<T> run<T extends Object>(
    String key, {
    required Duration ttl,
    required Future<T> Function() request,
  }) {
    if (_closed) {
      return Future.error(const OnlineException(OnlineErrorKind.closed));
    }
    if (ttl.isNegative) throw ArgumentError.value(ttl, 'ttl');
    final cached = _cache.remove(key);
    if (cached != null && _now().isBefore(cached.until)) {
      _cache[key] = cached;
      return cached.error != null
          ? Future.error(cached.error!)
          : Future.value(cached.value as T);
    }
    final pending = _pending[key];
    if (pending != null) return pending.done.future.then((value) => value as T);
    if (_isBlocked) return Future.error(_blockedError);
    if (_pending.length >= maxPendingRequests) {
      return Future.error(const OnlineException(OnlineErrorKind.queueFull));
    }
    final job = _Request(key, ttl, request, _generation);
    _pending[key] = job;
    _queue.add(job);
    final result = job.done.future.then((value) => value as T);
    if (!_draining) {
      _draining = true;
      scheduleMicrotask(() => unawaited(_drain()));
    }
    return result;
  }

  bool get _isBlocked =>
      _blockedUntil != null && _now().isBefore(_blockedUntil!);
  OnlineException get _blockedError =>
      OnlineException(_blockKind, retryAt: _blockedUntil);

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && !_closed) {
        final job = _queue.removeFirst();
        if (job.generation != _generation) continue;
        try {
          if (_isBlocked) throw _blockedError;
          if (_lastStarted != null) {
            final delay = _lastStarted!.add(minimumInterval).difference(_now());
            if (delay > Duration.zero) await _wait(delay);
          }
          if (_closed) break;
          if (job.generation != _generation) continue;
          if (_isBlocked) throw _blockedError;
          _lastStarted = _now();
          final value = await job.request();
          if (_closed) break;
          if (job.generation != _generation) continue;
          _rejections = 0;
          _remember(job.key, _Cached.value(value, _now().add(job.ttl)));
          job.done.complete(value);
        } on OnlineException catch (error) {
          if (_closed) break;
          final stale = job.generation != _generation;
          var reported = error;
          if (error.kind == OnlineErrorKind.rateLimited ||
              (!stale && error.kind == OnlineErrorKind.rejected)) {
            // A failed queued request does not extend the same cooldown.
            if (!_isBlocked) {
              final seconds = (60 * (1 << _rejections.clamp(0, 4))).clamp(
                60,
                900,
              );
              _rejections++;
              var until = _now().add(Duration(seconds: seconds));
              if (error.retryAt != null && error.retryAt!.isAfter(until)) {
                until = error.retryAt!;
              }
              _blockedUntil = until;
              _blockKind = error.kind;
            }
            reported = error.withRetryAt(_blockedUntil!);
          }
          if (stale) continue;
          var until = _now().add(negativeTtl);
          if (reported.retryAt != null && reported.retryAt!.isAfter(until)) {
            until = reported.retryAt!;
          }
          _remember(job.key, _Cached.error(reported, until));
          job.done.completeError(reported);
        } catch (_) {
          if (_closed) break;
          if (job.generation != _generation) continue;
          const error = OnlineException(OnlineErrorKind.transport);
          _remember(job.key, _Cached.error(error, _now().add(negativeTtl)));
          job.done.completeError(error);
        } finally {
          if (job.done.isCompleted && identical(_pending[job.key], job)) {
            _pending.remove(job.key);
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _remember(String key, _Cached value) {
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    _queue.clear();
    for (final job in _pending.values) {
      if (!job.done.isCompleted) {
        job.done.completeError(const OnlineException(OnlineErrorKind.closed));
      }
    }
    _pending.clear();
  }

  /// Account changes discard data/queued work, without bypassing rate limits.
  void invalidate() {
    if (_closed) return;
    _generation++;
    _cache.clear();
    _queue.clear();
    for (final job in _pending.values) {
      if (!job.done.isCompleted) {
        job.done.completeError(
          const OnlineException(OnlineErrorKind.sessionChanged),
        );
      }
    }
    _pending.clear();
  }
}

class _Request {
  _Request(this.key, this.ttl, this.request, this.generation);
  final String key;
  final Duration ttl;
  final Future<Object> Function() request;
  final int generation;
  final done = Completer<Object>();
}

class _Cached {
  _Cached.value(this.value, this.until) : error = null;
  _Cached.error(this.error, this.until) : value = null;
  final Object? value;
  final OnlineException? error;
  final DateTime until;
}

import '../domain/online_error.dart';
import '../qq/qq_track.dart';

/// A bounded catalog queue. Future entries contain identities, never URLs.
class RecommendationQueue {
  RecommendationQueue({this.maxTracks = 200, this.maxSeenIdentities = 1000}) {
    if (maxTracks < 20 || maxSeenIdentities < maxTracks) {
      throw ArgumentError('Invalid queue limits');
    }
  }

  final int maxTracks;
  final int maxSeenIdentities;
  final _seen = <String>{};
  List<QqTrack> _tracks = const [];
  int _index = 0;

  List<QqTrack> get tracks => _tracks;
  int get currentIndex => _index;
  int get remaining => _tracks.isEmpty ? 0 : _tracks.length - _index - 1;

  void replace(List<QqTrack> tracks, {int startIndex = 0}) {
    if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) {
      throw ArgumentError('Invalid queue');
    }
    if (tracks.length > maxTracks) {
      throw const OnlineException(OnlineErrorKind.queueFull);
    }
    final selected = tracks[startIndex].identity;
    final unique = <String, QqTrack>{};
    for (final track in tracks) {
      unique.putIfAbsent(track.identity, () => track);
    }
    _tracks = List.unmodifiable(unique.values);
    _index = _tracks.indexWhere((track) => track.identity == selected);
    _seen.clear();
    _seen.addAll(unique.keys);
  }

  void select(int index) {
    if (index < 0 || index >= _tracks.length) {
      throw RangeError.index(index, _tracks);
    }
    _index = index;
  }

  int append(List<QqTrack> incoming) {
    final unique = <String, QqTrack>{};
    for (final track in incoming) {
      if (!_seen.contains(track.identity)) {
        unique.putIfAbsent(track.identity, () => track);
      }
    }
    if (unique.isEmpty) return 0;
    final overflow = _tracks.length + unique.length - maxTracks;
    final trim = overflow.clamp(0, _index);
    final retained = _tracks.skip(trim).toList();
    final added = unique.values.take(maxTracks - retained.length).toList();
    _tracks = List.unmodifiable([...retained, ...added]);
    _index -= trim;
    _seen.addAll(added.map((track) => track.identity));
    while (_seen.length > maxSeenIdentities) {
      _seen.remove(_seen.first);
    }
    return added.length;
  }

  void clear() {
    _tracks = const [];
    _index = 0;
    _seen.clear();
  }
}

/// Only an explicitly started recommendation flow can append more batches.
class RecommendationContinuation {
  RecommendationContinuation({required this.queue, required this.onChanged});

  final RecommendationQueue queue;
  final void Function() onChanged;
  Future<List<QqTrack>> Function()? _next;
  Future<void>? _pending;
  int _generation = 0;
  bool _active = false;
  OnlineException? _error;

  bool get isActive => _active;
  bool get isLoading => _pending != null;
  OnlineException? get error => _error;

  void begin(Future<List<QqTrack>> Function() nextBatch) {
    stop();
    _next = nextBatch;
    _active = true;
  }

  Future<void> check({bool retry = false}) {
    if (!_active ||
        _next == null ||
        queue.tracks.isEmpty ||
        queue.remaining > 5 ||
        (_error != null && !retry)) {
      return Future.value();
    }
    if (_pending != null) return _pending!;
    final generation = _generation;
    final next = _next!;
    _error = null;
    final pending = Future<void>.microtask(() => _load(generation, next));
    _pending = pending;
    onChanged();
    return pending;
  }

  Future<void> _load(
    int generation,
    Future<List<QqTrack>> Function() next,
  ) async {
    if (generation != _generation) return;
    try {
      final incoming = await next();
      if (generation != _generation) return;
      if (queue.append(incoming.take(20).toList()) == 0) _active = false;
    } on OnlineException catch (error) {
      if (generation == _generation) _error = error;
    } catch (_) {
      if (generation == _generation) {
        _error = const OnlineException(OnlineErrorKind.transport);
      }
    } finally {
      if (generation == _generation) {
        _pending = null;
        onChanged();
      }
    }
  }

  void stop() {
    _generation++;
    _next = null;
    _active = false;
    _error = null;
    _pending = null;
  }
}

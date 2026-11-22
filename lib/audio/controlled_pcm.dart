import 'dart:async';
import 'dart:typed_data';

/// Sample data owned by the host. The audio engine never receives its URL.
abstract interface class ControlledPcmInput {
  int get channels;
  int get sampleRate;
  int get frames;
  bool get seekable;

  Future<ControlledPcmRead> openAt(int frame, PcmCancellation cancellation);
  void close();
}

abstract interface class ControlledPcmRead {
  Future<Uint8List> read(int maximum);
  void close();
}

final class PcmCancelled implements Exception {
  const PcmCancelled();
}

/// Cancels pending and active I/O without leaving a listener per chunk.
final class PcmCancellation {
  final Set<void Function()> _listeners = {};
  bool get cancelled => _cancelled;
  bool _cancelled = false;

  void check() {
    if (_cancelled) throw const PcmCancelled();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  Future<T> until<T>(Future<T> pending, {void Function(T)? discard}) {
    final done = Completer<T>();
    final unlisten = listen(() => done.completeError(const PcmCancelled()));
    unawaited(
      pending.then<void>(
        (value) {
          unlisten();
          if (!done.isCompleted) {
            done.complete(value);
          } else {
            discard?.call(value);
          }
        },
        onError: (Object error, StackTrace stack) {
          unlisten();
          if (!done.isCompleted) done.completeError(error, stack);
        },
      ),
    );
    return done.future;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../../audio/controlled_pcm.dart';

const lxMessageLimit = 64 * 1024;
const lxScriptExchangeLimit = 2400;
const lxScriptInFlightLimit = 64; // pending frames, not calls per song

typedef LxExchangeHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> request,
  PcmCancellation cancellation,
);

/// Multiplex HTTP operations over a single synchronous native message channel.
/// Only the foreground broker may authorize a connection. IDs are one-use,
/// in issue order; completions are delivered in completion order, not FIFO
/// request order. A cancelled slot isn't reusable until its handler unwinds.
final class LxScriptExchange {
  LxScriptExchange(this.scope, this.handler);
  final PcmCancellation scope;
  final LxExchangeHandler handler;
  final _slots = <int, _Slot>{};
  final _ready = Queue<int>();
  int _messages = 0;
  int _issued = 0;
  bool _closed = false;
  static final _ack = encodeLxMessage({'pending': true});

  Future<Uint8List> reply(Uint8List message) async {
    scope.check();
    if (_closed ||
        message.isEmpty ||
        message.length > lxMessageLimit ||
        ++_messages > lxScriptExchangeLimit) {
      throw const FormatException('LX broker message');
    }
    switch (message.first) {
      case 81: // Q: start; an immediate acknowledgement is not an HTTP result
        if (_slots.length >= lxScriptInFlightLimit) {
          throw const FormatException('LX broker slots');
        }
        final request = decodeLxMessage(Uint8List.sublistView(message, 1));
        final id = request.remove('id');
        if (id is! int || id != _issued + 1) {
          throw const FormatException('LX request id');
        }
        _issued = id;
        final slot = _slots[id] = _Slot(id);
        slot.unlink = scope.listen(slot.scope.cancel);
        slot.done = _run(slot, request);
        return _ack;
      case 80: // P: take at most one ready response (never bundle large frames)
        if (message.length != 1 || _slots.isEmpty) {
          throw const FormatException('LX poll');
        }
        if (_ready.isEmpty) return _ack;
        final slot = _slots[_ready.removeFirst()]!;
        final result = slot.result!;
        _release(slot);
        return result;
      case 88: // X<decimal id>: one request, not a cancellation of its peers
        if (message.length < 2 ||
            message.length > 1 + lxScriptExchangeLimit.toString().length) {
          throw const FormatException('LX cancel');
        }
        final text = ascii.decode(Uint8List.sublistView(message, 1));
        final id = int.tryParse(text);
        final slot = _slots[id];
        if (slot == null || slot.scope.cancelled || text != '$id') {
          throw const FormatException('LX cancel id');
        }
        await _abort(slot);
        return _ack;
      default:
        throw const FormatException('LX broker command');
    }
  }

  Future<void> _run(_Slot slot, Map<String, Object?> request) async {
    try {
      final value = await handler(request, slot.scope);
      if (slot.scope.cancelled) return;
      slot.result = encodeLxMessage({...value, 'id': slot.id});
    } catch (_) {
      if (slot.scope.cancelled) return;
      slot.result = encodeLxMessage({'id': slot.id, 'error': 'denied'});
    }
    _ready.addLast(slot.id);
  }

  void _release(_Slot slot) {
    if (_slots.remove(slot.id) == null) return;
    slot.unlink();
    slot.scope.cancel();
    slot.result = null;
  }

  Future<void> _abort(_Slot slot) async {
    _ready.remove(slot.id);
    slot.scope.cancel();
    await slot.done;
    _release(slot);
  }

  Future<void> close() async {
    _closed = true;
    // Signal every peer before waiting for cleanup. A future run may use the
    // worker only after its outstanding sockets and callbacks have finished.
    await Future.wait(_slots.values.toList().map(_abort));
  }
}

final class _Slot {
  _Slot(this.id);
  final int id;
  final scope = PcmCancellation();
  late final void Function() unlink;
  late final Future<void> done;
  Uint8List? result;
}

Uint8List encodeLxMessage(Map<String, Object?> object) {
  final bytes = utf8.encode(jsonEncode(object));
  if (bytes.length > lxMessageLimit) throw const FormatException('LX size');
  return bytes;
}

Map<String, Object?> decodeLxMessage(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > lxMessageLimit) {
    throw const FormatException('LX size');
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, Object?>) throw const FormatException('LX object');
  return value;
}

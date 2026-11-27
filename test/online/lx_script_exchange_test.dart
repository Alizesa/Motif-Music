import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/lx/lx_script_exchange.dart';

Uint8List _q(Object? id) => Uint8List.fromList([
  81,
  ...encodeLxMessage({
    'id': id,
    'url': 'https://api.fixture.invalid',
    'options': {},
  }),
]);
Future<Map<String, Object?>> _reply(LxScriptExchange e, Object cmd) async =>
    decodeLxMessage(
      await e.reply(cmd is String ? utf8.encode(cmd) : cmd as Uint8List),
    );
const _ack = {'pending': true};
final _invalid = throwsA(isA<FormatException>());
Future<void> _jobs() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'two slots, completion order, one-use IDs, no ID in HTTP options',
    () async {
      final gates = <Completer<Map<String, Object?>>>[];
      final e = LxScriptExchange(PcmCancellation(), (m, c) {
        expect(m.keys, unorderedEquals(['url', 'options']));
        final wait = Completer<Map<String, Object?>>();
        gates.add(wait);
        return c.until(wait.future);
      });
      addTearDown(e.close);
      expect(await _reply(e, _q(1)), _ack);
      expect(await _reply(e, _q(2)), _ack);
      await expectLater(_reply(e, _q(3)), _invalid);
      expect(await _reply(e, 'P'), _ack);
      gates[1].complete({
        'response': {'body': 'second'},
      });
      await _jobs();
      gates[0].complete({
        'response': {'body': 'first'},
      });
      await _jobs();
      expect(await _reply(e, 'P'), {
        'id': 2,
        'response': {'body': 'second'},
      });
      expect(await _reply(e, _q(3)), _ack);
      expect(await _reply(e, 'P'), {
        'id': 1,
        'response': {'body': 'first'},
      });
      expect(await _reply(e, 'X3'), _ack);
      await expectLater(_reply(e, _q(2)), _invalid);
    },
  );

  test(
    'cancelling one slot waits for cleanup and discards its late response',
    () async {
      final pending = <Completer<Map<String, Object?>>>[];
      final scopes = <PcmCancellation>[];
      final e = LxScriptExchange(PcmCancellation(), (_, c) {
        scopes.add(c);
        final wait = Completer<Map<String, Object?>>();
        pending.add(wait);
        return wait.future;
      });
      await _reply(e, _q(1));
      await _reply(e, _q(2));
      var retired = false;
      final cancelling = _reply(e, 'X1').then((v) {
        retired = true;
        return v;
      });
      await _jobs();
      expect(scopes[0].cancelled, isTrue);
      expect(scopes[1].cancelled, isFalse);
      expect(retired, isFalse);
      await expectLater(_reply(e, _q(3)), _invalid);
      pending[0].complete({
        'response': {'body': 'stale'},
      });
      expect(await cancelling, _ack);
      await _reply(e, _q(3));
      pending[1].complete({
        'response': {'body': 'second'},
      });
      await _jobs();
      expect((await _reply(e, 'P'))['id'], 2);
      expect(await _reply(e, 'P'), _ack);
      var closed = false;
      final closing = e.close().then((_) {
        closed = true;
      });
      await _jobs();
      expect(scopes.last.cancelled, isTrue);
      expect(closed, isFalse);
      pending[2].completeError(StateError('late'));
      await closing;
      expect(closed, isTrue);
      await expectLater(_reply(e, _q(4)), _invalid);
    },
  );

  test('owner cancellation aborts both pending handlers', () async {
    final owner = PcmCancellation();
    final scopes = <PcmCancellation>[];
    int cleaned = 0;
    final e = LxScriptExchange(owner, (_, c) async {
      scopes.add(c);
      try {
        return await c.until(Completer<Map<String, Object?>>().future);
      } finally {
        cleaned++;
      }
    });
    await _reply(e, _q(1));
    await _reply(e, _q(2));
    owner.cancel();
    await e.close();
    expect(scopes.every((c) => c.cancelled), isTrue);
    expect(cleaned, 2);
    await expectLater(_reply(e, 'P'), throwsA(isA<PcmCancelled>()));
  });

  test(
    'aborting a ready but undelivered result does not misroute the next poll',
    () async {
      final e = LxScriptExchange(
        PcmCancellation(),
        (_, _) async => {
          'response': {'body': 'ok'},
        },
      );
      addTearDown(e.close);
      await _reply(e, _q(1));
      await _reply(e, _q(2));
      await _jobs();
      await _reply(e, 'X1');
      expect((await _reply(e, 'P'))['id'], 2);
      await expectLater(_reply(e, 'P'), _invalid);
    },
  );

  test(
    'host enforces IDs, response size, candidate count and poll ceiling',
    () async {
      final e = LxScriptExchange(
        PcmCancellation(),
        (_, _) async => {
          'response': {'body': 'x' * lxMessageLimit},
        },
      );
      addTearDown(e.close);
      for (final id in [null, 0, 1.0, '1', 2, 9999]) {
        await expectLater(_reply(e, _q(id)), _invalid);
      }
      await _reply(e, _q(1));
      await expectLater(_reply(e, _q(1)), _invalid);
      for (final cmd in ['X', 'X2', 'X01', 'X+1', 'P1', 'Q{}']) {
        await expectLater(_reply(e, cmd), _invalid);
      }
      await _jobs();
      expect(await _reply(e, 'P'), {'id': 1, 'error': 'denied'});
      for (var n = 2; n <= 12; n++) {
        await _reply(e, _q(n));
        await _reply(e, 'X$n');
      }
      await expectLater(_reply(e, _q(13)), _invalid);
      final polls = LxScriptExchange(
        PcmCancellation(),
        (_, c) => c.until(Completer<Map<String, Object?>>().future),
      );
      addTearDown(polls.close);
      await _reply(polls, _q(1));
      for (var i = 1; i < lxScriptExchangeLimit; i++) {
        await _reply(polls, 'P');
      }
      await expectLater(_reply(polls, 'P'), _invalid);
    },
  );
}

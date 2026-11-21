import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/online/domain/online_error.dart';

import 'online_fakes.dart';

Matcher kind(OnlineErrorKind value) =>
    isA<OnlineException>().having((error) => error.kind, 'kind', value);

void main() {
  test(
    'coalesces repeated work and then serves cache without network',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator();
      addTearDown(gate.close);
      var calls = 0;
      Future<int> send() async => ++calls;
      final values = await Future.wait(
        List.generate(
          20,
          (_) =>
              gate.run('same', ttl: const Duration(minutes: 10), request: send),
        ),
      );
      expect(values, everyElement(1));
      expect(await gate.run('same', ttl: Duration.zero, request: send), 1);
      expect(calls, 1);
      expect(clock.waits, isEmpty);
    },
  );

  test('different keys are serial and respect minimum spacing', () async {
    final clock = TestClock();
    final gate = clock.coordinator();
    addTearDown(gate.close);
    var active = 0;
    var peak = 0;
    final starts = <DateTime>[];
    Future<int> send() async {
      active++;
      if (active > peak) peak = active;
      starts.add(clock.now());
      await Future<void>.delayed(Duration.zero);
      active--;
      return starts.length;
    }

    await Future.wait(
      List.generate(
        3,
        (i) => gate.run('$i', ttl: Duration.zero, request: send),
      ),
    );
    expect(peak, 1);
    expect(starts[1].difference(starts[0]), const Duration(milliseconds: 1500));
    expect(starts[2].difference(starts[1]), const Duration(milliseconds: 1500));
  });

  test(
    'cache expiry and bounded LRU eviction require new explicit work',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator(maxCacheEntries: 2);
      addTearDown(gate.close);
      var calls = 0;
      Future<int> load(String key) => gate.run(
        key,
        ttl: const Duration(minutes: 10),
        request: () async => ++calls,
      );
      expect(await load('a'), 1);
      expect(await load('b'), 2);
      expect(await load('a'), 1);
      expect(await load('c'), 3);
      expect(await load('b'), 4);
      clock.advance(const Duration(minutes: 11));
      expect(await load('b'), 5);
    },
  );

  test(
    'transient failures are negative cached and never automatically retried',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator();
      addTearDown(gate.close);
      var calls = 0;
      Future<int> load() => gate.run(
        'fail',
        ttl: Duration.zero,
        request: () async {
          calls++;
          throw const OnlineException(OnlineErrorKind.transport);
        },
      );
      await expectLater(load(), throwsA(kind(OnlineErrorKind.transport)));
      await expectLater(load(), throwsA(kind(OnlineErrorKind.transport)));
      expect(calls, 1);
      clock.advance(const Duration(seconds: 31));
      await expectLater(load(), throwsA(kind(OnlineErrorKind.transport)));
      expect(calls, 2);
    },
  );

  test(
    'rate limit stops queued work and honors retry-after across keys',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator();
      addTearDown(gate.close);
      var calls = 0;
      final until = clock.now().add(const Duration(minutes: 5));
      Future<int> fail() async {
        calls++;
        throw OnlineException(OnlineErrorKind.rateLimited, retryAt: until);
      }

      final results = [
        gate.run('one', ttl: Duration.zero, request: fail),
        gate.run('two', ttl: Duration.zero, request: fail),
      ];
      await expectLater(
        Future.wait(results),
        throwsA(kind(OnlineErrorKind.rateLimited)),
      );
      expect(calls, 1);
      clock.advance(const Duration(minutes: 4));
      await expectLater(
        gate.run('three', ttl: Duration.zero, request: fail),
        throwsA(
          isA<OnlineException>().having((e) => e.retryAt, 'deadline', until),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'cached success stays readable while all new requests are paused',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator();
      addTearDown(gate.close);
      var calls = 0;
      Future<int> load() => gate.run(
        'ok',
        ttl: const Duration(hours: 1),
        request: () async => ++calls,
      );
      await load();
      await expectLater(
        gate.run<int>(
          'blocked',
          ttl: Duration.zero,
          request: () async =>
              throw const OnlineException(OnlineErrorKind.rejected),
        ),
        throwsA(kind(OnlineErrorKind.rejected)),
      );
      expect(await load(), 1);
      expect(calls, 1);
    },
  );

  test(
    'consecutive remote rejections increase cooldown without a retry loop',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator();
      addTearDown(gate.close);
      Future<int> send() async =>
          throw const OnlineException(OnlineErrorKind.rejected);
      final firstAt = clock.now();
      await expectLater(
        gate.run('one', ttl: Duration.zero, request: send),
        throwsA(
          isA<OnlineException>().having(
            (e) => e.retryAt,
            'first pause',
            firstAt.add(const Duration(seconds: 60)),
          ),
        ),
      );
      clock.advance(const Duration(seconds: 61));
      final secondAt = clock.now();
      await expectLater(
        gate.run('two', ttl: Duration.zero, request: send),
        throwsA(
          isA<OnlineException>().having(
            (e) => e.retryAt,
            'second pause',
            secondAt.add(const Duration(seconds: 120)),
          ),
        ),
      );
    },
  );

  test(
    'pending bound rejects extra work without disturbing joined callers',
    () async {
      final clock = TestClock();
      final gate = clock.coordinator(maxPendingRequests: 1);
      addTearDown(gate.close);
      final pending = Completer<int>();
      final first = gate.run(
        'a',
        ttl: Duration.zero,
        request: () => pending.future,
      );
      final joined = gate.run('a', ttl: Duration.zero, request: () async => 99);
      await expectLater(
        gate.run('b', ttl: Duration.zero, request: () async => 2),
        throwsA(kind(OnlineErrorKind.queueFull)),
      );
      pending.complete(7);
      expect(await Future.wait([first, joined]), [7, 7]);
    },
  );

  test(
    'close before drain prevents any request and closes future callers',
    () async {
      final gate = TestClock().coordinator();
      var calls = 0;
      final result = gate.run(
        'pending',
        ttl: Duration.zero,
        request: () async => ++calls,
      );
      final check = expectLater(result, throwsA(kind(OnlineErrorKind.closed)));
      gate.close();
      await check;
      await expectLater(
        gate.run('later', ttl: Duration.zero, request: () async => ++calls),
        throwsA(kind(OnlineErrorKind.closed)),
      );
      expect(calls, 0);
    },
  );

  test(
    'close discards late active results and never starts queued work',
    () async {
      final gate = TestClock().coordinator();
      final started = Completer<void>();
      final reply = Completer<int>();
      var calls = 0;
      final first = gate.run(
        'one',
        ttl: Duration.zero,
        request: () {
          calls++;
          started.complete();
          return reply.future;
        },
      );
      final second = gate.run(
        'two',
        ttl: Duration.zero,
        request: () async => ++calls,
      );
      final check = expectLater(
        Future.wait([first, second]),
        throwsA(kind(OnlineErrorKind.closed)),
      );
      await started.future;
      gate.close();
      reply.complete(42);
      await check;
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    },
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_ordered_source.dart';
import 'package:motif/online/lx/lx_request_error.dart';

import '../support/ordered_script_stub.dart';
import 'playback_fakes.dart';

void main() {
  testWidgets(
    'a non-cancellable provider cannot stall the order or deliver a late winner',
    (tester) async {
      for (final cancel in [false, true]) {
        final owner = PcmCancellation(), gate = Completer<String>();
        final calls = <String>[];
        final result = trySourceOrder<String>(
          sources: [FakePlaybackSource('qq'), OrderedScriptStub('A')],
          quality: OnlineQuality.high,
          registered: (_) => true,
          owner: owner,
          attempt: (s, _, _, _) {
            calls.add(s.sourceId);
            return gate.future;
          },
        );
        final stopped = expectLater(
          result,
          throwsA(
            cancel
                ? isA<PcmCancelled>()
                : isA<LxRequestException>().having(
                    (e) => e.reason,
                    'reason',
                    LxRequestFailure.scriptTimeout,
                  ),
          ),
        );
        if (cancel) {
          owner.cancel();
        } else {
          await tester.pump(const Duration(seconds: 61));
        }
        await stopped;
        gate.complete('late');
        await tester.pump();
        expect(calls, ['qq']);
      }
    },
  );

  testWidgets(
    'one deadline for ordered preparation; accepted download has no 60s file limit',
    (tester) async {
      for (final acceptFile in [false, true]) {
        final gate = Completer<String>();
        var attempts = 0;
        final next = trySourceOrder<String>(
          sources: [OrderedScriptStub('A'), OrderedScriptStub('B')],
          quality: OnlineQuality.high,
          registered: (_) => true,
          owner: PcmCancellation(),
          attempt: (_, _, scope, accept) {
            attempts++;
            if (acceptFile) accept();
            return scope.until(gate.future);
          },
        );
        final result = expectLater(
          next,
          acceptFile
              ? completion('mp3')
              : throwsA(
                  isA<LxRequestException>().having(
                    (e) => e.reason,
                    'reason',
                    LxRequestFailure.scriptTimeout,
                  ),
                ),
        );
        await tester.pump(const Duration(seconds: 61));
        gate.complete('mp3');
        await result;
        expect(attempts, 1);
      }
    },
  );
}

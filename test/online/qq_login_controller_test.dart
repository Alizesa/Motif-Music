import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/online/qq/auth/qq_auth_client.dart';
import 'package:motif/online/qq/auth/qq_login_controller.dart';
import 'package:motif/online/qq/auth/qq_login_protocol.dart';
import 'package:motif/online/qq/auth/qq_session_manager.dart';
import 'package:motif/online/network/qq_account_transport.dart';

import 'qq_auth_fakes.dart';

void main() {
  late QqSessionManager session;
  late QqAuthClient client;
  late FakeQqAccountTransport transport;
  late QqLoginController controller;
  setUp(() async {
    session = QqSessionManager(vault: MemoryQqVault());
    await session.initialize();
    transport = FakeQqAccountTransport();
    client = QqAuthClient(transport: transport);
    controller = QqLoginController(
      sessions: session,
      client: client,
      verify: (_) async => null,
      pollInterval: const Duration(hours: 1),
    );
  });
  tearDown(() async {
    controller.dispose();
    client.close();
    await session.close();
  });

  test(
    'replacing a delayed QR challenge cannot overwrite the new image or status',
    () async {
      final old = Completer<QqAccountResponse>();
      transport.reply = (_) => transport.requests.length == 1
          ? old.future
          : Future.value(
              QqAccountResponse(
                status: 200,
                bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
                setCookies: ['qrsig=new; Path=/'],
              ),
            );
      final first = controller.startQr(QqQrMethod.qq);
      await Future<void>.delayed(Duration.zero);
      await controller.startQr(QqQrMethod.qq);
      old.complete(
        QqAccountResponse(
          status: 200,
          bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
          setCookies: ['qrsig=old; Path=/'],
        ),
      );
      await first;
      expect(controller.qr?.key, 'new');
      expect(controller.status, QqLoginUiStatus.waitingScan);
    },
  );

  test('SMS code is tied to the phone for which it was requested', () async {
    transport.reply = (request) async => accountModuleResponse(request, {});
    await controller.startPhone();
    await controller.sendCode('13800000000', '86');
    await controller.loginPhone('13900000000', '86', '123456');
    expect(transport.requests, hasLength(1));
    expect(session.account, isNull);
    expect(controller.error, contains('当前手机号'));
  });

  test('verified SMS login publishes only after secure session save', () async {
    transport.reply = (request) async {
      final method = (request.jsonBody!['phoneLogin'] as Map)['method'];
      return accountModuleResponse(
        request,
        method == 'Login' ? loginData() : {},
      );
    };
    await controller.startPhone();
    await controller.sendCode('13800000000', '86');
    await controller.loginPhone('13800000000', '86', '123456');
    expect(session.account?.id, '42');
    expect(controller.status, QqLoginUiStatus.success);
  });

  test(
    'cancelling human verification never sends the SMS request again',
    () async {
      transport.reply = (request) async => accountModuleResponse(request, {
        'securityURL': 'https://ssl.captcha.qq.com/verify',
      }, code: 20276);
      await controller.startPhone();
      await controller.sendCode('13800000000', '86');
      expect(transport.requests, hasLength(1));
      expect(controller.status, QqLoginUiStatus.failed);
    },
  );

  test('a verification is followed by at most one retry of the original SMS operation', () async {
    controller.dispose();
    controller = QqLoginController(
      sessions: session,
      client: client,
      verify: (challenge) async =>
          const QqVerificationResult(cookie: 'verified=1'),
      pollInterval: const Duration(hours: 1),
    );
    transport.reply = (request) async => transport.requests.length == 1
        ? accountModuleResponse(request, {
            'securityURL': 'https://ssl.captcha.qq.com/verify',
          }, code: 20276)
        : accountModuleResponse(request, {});
    await controller.startPhone();
    await controller.sendCode('13800000000', '86');
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.cookie, contains('verified=1'));
    expect(controller.sendWaitSeconds, greaterThan(0));
  });
}

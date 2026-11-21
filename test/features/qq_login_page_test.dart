import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/features/account/qq_login_page.dart';
import 'package:motif/online/qq/auth/qq_auth_client.dart';
import 'package:motif/online/qq/auth/qq_session_manager.dart';
import 'package:motif/online/network/qq_account_transport.dart';

import 'dart:typed_data';

import '../online/qq_auth_fakes.dart';

void main() {
  testWidgets('login page switches to SMS and sends only after user input', (
    tester,
  ) async {
    final session = QqSessionManager(vault: MemoryQqVault());
    final transport = FakeQqAccountTransport()
      ..reply = (request) async => request.uri.path == '/ptqrshow'
          ? QqAccountResponse(
              status: 200,
              bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
              setCookies: ['qrsig=fixture; Path=/'],
            )
          : accountModuleResponse(request, {});
    final client = QqAuthClient(transport: transport);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: QqLoginPage(sessions: session, client: client),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('手机号'));
      await tester.pumpAndSettle();
      final before = transport.requests.length;
      await tester.enterText(
        find.byKey(const Key('qq-login-phone')),
        '13800000000',
      );
      await tester.tap(find.byKey(const Key('qq-send-code')));
      await tester.pumpAndSettle();
      expect(transport.requests.length, before + 1);
      expect(find.byKey(const Key('qq-login-code')), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      client.close();
      await session.close();
    }
  });
}

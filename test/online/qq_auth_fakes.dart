import 'dart:convert';
import 'dart:typed_data';

import 'package:motif/online/network/qq_account_transport.dart';
import 'package:motif/online/qq/auth/qq_credential.dart';
import 'package:motif/online/qq/auth/qq_session_manager.dart';

class MemoryQqVault implements QqCredentialVault {
  String? value;
  Object? error;
  Future<void>? nextWriteWait;
  final writes = <String>[];
  @override
  Future<String?> read() async {
    if (error != null) throw error!;
    return value;
  }

  @override
  Future<void> write(String text) async {
    final pending = nextWriteWait;
    nextWriteWait = null;
    if (pending != null) await pending;
    if (error != null) throw error!;
    writes.add(text);
    value = text;
  }
}

class FakeQqAccountTransport implements QqAccountTransport {
  final requests = <QqAccountRequest>[];
  late Future<QqAccountResponse> Function(QqAccountRequest) reply;
  bool closed = false;
  @override
  Future<QqAccountResponse> send(QqAccountRequest request) async {
    requests.add(request);
    return reply(request);
  }

  @override
  void close() => closed = true;
}

QqAccountResponse accountResponse(
  Object data, {
  int status = 200,
  List<String> cookies = const [],
  String? location,
}) => QqAccountResponse(
  status: status,
  bytes: Uint8List.fromList(
    utf8.encode(data is String ? data : jsonEncode(data)),
  ),
  setCookies: cookies,
  location: location,
);

QqAccountResponse accountModuleResponse(
  QqAccountRequest request,
  Object data, {
  int code = 0,
}) {
  final key = request.jsonBody!.keys.firstWhere((key) => key != 'comm');
  return accountResponse({
    'code': 0,
    key: {'code': code, 'data': data},
  });
}

Map<String, Object?> loginData({
  String id = '42',
  String key = 'fixture-key',
}) => {'musicid': id, 'musickey': key, 'nick': 'Account $id', 'loginType': 2};

QqCredential testCredential({String id = '42', String key = 'fixture-key'}) =>
    QqCredential.fromLoginData(loginData(id: id, key: key));

Future<QqSessionManager> signedSession(
  MemoryQqVault vault, {
  String id = '42',
}) async {
  final sessions = QqSessionManager(vault: vault);
  await sessions.initialize();
  final attempt = await sessions.beginLogin();
  await sessions.completeLogin(attempt, testCredential(id: id));
  return sessions;
}

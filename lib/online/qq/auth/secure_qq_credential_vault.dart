import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'qq_credential.dart';

class SecureQqCredentialVault implements QqCredentialVault {
  const SecureQqCredentialVault({this.storage = const FlutterSecureStorage()});
  final FlutterSecureStorage storage;
  static const _key = 'motif.qq.session.v1';

  @override
  Future<String?> read() => storage.read(key: _key);
  @override
  Future<void> write(String value) => storage.write(key: _key, value: value);
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'qq_auth_error.dart';
import 'qq_credential.dart';

enum QqSessionStatus {
  loading,
  anonymous,
  authenticating,
  signedIn,
  expired,
  storageError,
}

class QqSessionSnapshot {
  const QqSessionSnapshot({required this.epoch, required this.credential});
  final int epoch;
  final QqCredential? credential;
}

/// Session ownership is independent of routes. All vault writes are serialized,
/// so a delayed login/renewal cannot persist over a newer logout or account.
class QqSessionManager {
  QqSessionManager({required this.vault});
  final QqCredentialVault vault;
  final _changes = StreamController<QqSessionStatus>.broadcast();
  Future<void> _vaultTail = Future.value();
  Future<void>? _initializing;
  QqCredential? _credential;
  String? _deviceId;
  int _epoch = 0;
  bool _closed = false;
  QqSessionStatus _status = QqSessionStatus.loading;
  String? _error;

  Stream<QqSessionStatus> get changes => _changes.stream;
  QqSessionStatus get status => _status;
  QqAccount? get account => _credential?.account;
  String? get error => _error;
  int get epoch => _epoch;
  QqSessionSnapshot get snapshot =>
      QqSessionSnapshot(epoch: _epoch, credential: _credential);
  bool get isReady =>
      _deviceId != null && _status != QqSessionStatus.storageError;
  String get deviceId =>
      _deviceId ?? (throw const QqAuthException(QqAuthErrorKind.storage));

  bool isCurrent(QqSessionSnapshot value) =>
      !_closed &&
      value.epoch == _epoch &&
      identical(value.credential, _credential);
  bool ownsAttempt(int epoch) =>
      !_closed && epoch == _epoch && _status == QqSessionStatus.authenticating;

  Future<void> initialize() {
    if (_closed || isReady) return Future.value();
    return _initializing ??= Future<void>.microtask(_initialize);
  }

  Future<void> _initialize() async {
    try {
      final stored = await vault.read();
      if (_closed) return;
      if (stored == null) {
        final random = Random.secure();
        _deviceId = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await _serialWrite(encodeQqSession(_deviceId!, null));
      } else {
        if (stored.length > 65536) throw const FormatException();
        final value = jsonDecode(stored);
        if (value is! Map<String, Object?> ||
            value['version'] != 1 ||
            value['deviceId'] is! String ||
            !RegExp(r'^[A-Za-z0-9]{16,32}$')
                .hasMatch(value['deviceId']! as String)) {
          throw const FormatException();
        }
        _deviceId = value['deviceId']! as String;
        _credential = value['credential'] == null
            ? null
            : QqCredential.fromSecretJson(value['credential']);
      }
      if (_closed) return;
      _status = _credential == null
          ? QqSessionStatus.anonymous
          : QqSessionStatus.signedIn;
      _error = null;
    } catch (_) {
      if (!_closed) {
        _status = QqSessionStatus.storageError;
        _error = '无法读取安全登录存储，请重试。';
      }
    } finally {
      _initializing = null;
      _notify();
    }
  }

  Future<int> beginLogin() async {
    await initialize();
    if (_closed || !isReady) {
      throw const QqAuthException(QqAuthErrorKind.storage);
    }
    final epoch = ++_epoch;
    _credential = null;
    _status = QqSessionStatus.authenticating;
    _error = null;
    _notify();
    try {
      await _serialWrite(encodeQqSession(deviceId, null));
    } catch (_) {
      if (epoch == _epoch) {
        _status = QqSessionStatus.storageError;
        _error = '无法清除旧登录记录，请重试。';
        _notify();
      }
      throw const QqAuthException(QqAuthErrorKind.storage);
    }
    if (!ownsAttempt(epoch)) {
      throw const QqAuthException(QqAuthErrorKind.cancelled);
    }
    return epoch;
  }

  Future<bool> completeLogin(int attempt, QqCredential value) async {
    if (!ownsAttempt(attempt)) return false;
    try {
      return await _serial(() async {
        if (!ownsAttempt(attempt)) return false;
        await vault.write(encodeQqSession(deviceId, value));
        if (!ownsAttempt(attempt)) return false;
        _credential = value;
        _epoch++;
        _status = QqSessionStatus.signedIn;
        _error = null;
        _notify();
        return true;
      });
    } catch (_) {
      if (ownsAttempt(attempt)) _error = '无法安全保存登录，请重试。';
      _notify();
      throw const QqAuthException(QqAuthErrorKind.storage);
    }
  }

  Future<bool> renew(QqSessionSnapshot previous, QqCredential value) async {
    if (!isCurrent(previous) ||
        value.accountId != previous.credential?.accountId) {
      return false;
    }
    return _serial(() async {
      if (!isCurrent(previous)) return false;
      await vault.write(encodeQqSession(deviceId, value));
      if (!isCurrent(previous)) return false;
      _credential = value;
      _epoch++;
      _notify();
      return true;
    });
  }

  Future<void> logout({bool expired = false}) async {
    if (_closed) return;
    await initialize();
    if (_closed) return;
    final epoch = ++_epoch;
    _credential = null;
    _status = expired ? QqSessionStatus.expired : QqSessionStatus.anonymous;
    _error = expired ? '登录已失效，请重新登录。' : null;
    _notify();
    try {
      await _serialWrite(encodeQqSession(deviceId, null));
    } catch (_) {
      if (_epoch == epoch) {
        _status = QqSessionStatus.storageError;
        _error = '无法清除安全登录记录，请重试。';
        _notify();
      }
      throw const QqAuthException(QqAuthErrorKind.storage);
    }
  }

  Future<void> reject(QqSessionSnapshot value) async {
    if (isCurrent(value) && value.credential != null) {
      await logout(expired: true);
    }
  }

  Future<void> cancelLogin(int attempt) async {
    if (ownsAttempt(attempt)) await logout();
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _vaultTail.then((_) => work());
    _vaultTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _serialWrite(String value) => _serial(() => vault.write(value));
  void _notify() {
    if (!_closed) _changes.add(_status);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _epoch++;
    await _vaultTail;
    await _changes.close();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'qq_auth_client.dart';
import 'qq_auth_error.dart';
import 'qq_credential.dart';
import 'qq_login_protocol.dart';
import 'qq_session_manager.dart';

enum QqLoginUiStatus {
  idle,
  loading,
  waitingScan,
  waitingConfirm,
  verifying,
  expired,
  failed,
  success,
}

class QqLoginController extends ChangeNotifier {
  QqLoginController({
    required this.sessions,
    required this.client,
    required this.verify,
    this.pollInterval = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final QqSessionManager sessions;
  final QqAuthClient client;
  final QqVerify verify;
  final Duration pollInterval;
  final DateTime Function() _now;
  Timer? _poll;
  Timer? _countdown;
  DateTime? _deadline;
  DateTime? _sendAgainAt;
  int _generation = 0;
  int? _attempt;
  bool _closed = false;
  bool _working = false;
  QqQrChallenge? _qr;
  QqLoginUiStatus _status = QqLoginUiStatus.idle;
  String? _error;
  String _smsCookie = '';
  String? _sentPhone;
  String? _sentCountry;

  QqQrChallenge? get qr => _qr;
  QqLoginUiStatus get status => _status;
  bool get working => _working;
  String? get error => _error;
  int get sendWaitSeconds => _sendAgainAt == null
      ? 0
      : _sendAgainAt!.difference(_now()).inSeconds.clamp(0, 60);
  String get message => switch (_status) {
    QqLoginUiStatus.loading => '正在获取二维码…',
    QqLoginUiStatus.waitingScan => _qr?.scanMessage ?? '请扫码',
    QqLoginUiStatus.waitingConfirm => '已扫码，请在手机上确认登录',
    QqLoginUiStatus.verifying => '请完成安全验证',
    QqLoginUiStatus.expired => '二维码已过期，请刷新',
    QqLoginUiStatus.failed => '登录未完成，请重试',
    QqLoginUiStatus.success => '登录成功',
    _ => '',
  };

  bool _active(int generation) =>
      !_closed &&
      generation == _generation &&
      _attempt != null &&
      sessions.ownsAttempt(_attempt!);

  Future<int> _begin() async {
    final generation = ++_generation;
    _poll?.cancel();
    _poll = null;
    final previous = _attempt;
    _attempt = null;
    if (previous != null) await sessions.cancelLogin(previous);
    if (_closed || generation != _generation) {
      throw const QqAuthException(QqAuthErrorKind.cancelled);
    }
    final attempt = await sessions.beginLogin();
    if (_closed || generation != _generation) {
      await sessions.cancelLogin(attempt);
      throw const QqAuthException(QqAuthErrorKind.cancelled);
    }
    _attempt = attempt;
    return generation;
  }

  Future<void> startQr(
    QqQrMethod method, {
    String verificationCookie = '',
  }) async {
    if (_closed) return;
    _working = true;
    _error = null;
    _qr = null;
    _status = QqLoginUiStatus.loading;
    _notify();
    final starting = _begin();
    final generation = _generation;
    try {
      await starting;
      final challenge = await client.createQr(
        method,
        isActive: () => _active(generation),
      );
      if (!_active(generation)) return;
      _qr = challenge.withCookies(
        challenge.cookie,
        verificationCookie: verificationCookie,
      );
      _deadline = _now().add(const Duration(minutes: 3));
      _status = QqLoginUiStatus.waitingScan;
      _schedule(generation);
    } catch (error) {
      if (!_closed && generation == _generation) {
        _fail(error);
      }
    } finally {
      if (!_closed && generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  void _schedule(int generation) {
    _poll?.cancel();
    if (_active(generation)) {
      _poll = Timer(pollInterval, () => unawaited(_checkQr(generation)));
    }
  }

  Future<void> _checkQr(int generation) async {
    if (!_active(generation) || _qr == null) return;
    if (_deadline == null || !_now().isBefore(_deadline!)) {
      _status = QqLoginUiStatus.expired;
      _notify();
      return;
    }
    try {
      final result = await client.checkQr(
        _qr!,
        sessions.deviceId,
        isActive: () => _active(generation),
      );
      if (!_active(generation)) return;
      _qr = result.challenge;
      if (result.status == QqQrStatus.success) {
        await _finish(generation, result.credential!);
        return;
      }
      _status = switch (result.status) {
        QqQrStatus.waitingScan =>
          _status == QqLoginUiStatus.waitingConfirm
              ? QqLoginUiStatus.waitingConfirm
              : QqLoginUiStatus.waitingScan,
        QqQrStatus.waitingConfirm => QqLoginUiStatus.waitingConfirm,
        QqQrStatus.expired => QqLoginUiStatus.expired,
        _ => QqLoginUiStatus.failed,
      };
      _notify();
      if (result.status == QqQrStatus.waitingScan ||
          result.status == QqQrStatus.waitingConfirm) {
        _schedule(generation);
      }
    } on QqVerificationRequired catch (error) {
      if (!_active(generation)) return;
      _status = QqLoginUiStatus.verifying;
      _notify();
      final method = _qr!.method;
      final result = await verify(error.challenge);
      if (!_active(generation)) return;
      if (result == null) {
        _fail(const QqAuthException(QqAuthErrorKind.cancelled));
        return;
      }
      // OAuth codes are single-use. Resume with a fresh QR grant after proof.
      await startQr(
        method,
        verificationCookie: mergeQqCookies(
          error.challenge.cookie,
          result.cookie,
        ),
      );
    } catch (error) {
      if (_active(generation)) _fail(error);
    }
  }

  Future<void> startPhone() async {
    if (_closed) return;
    _qr = null;
    _status = QqLoginUiStatus.idle;
    _error = null;
    _working = true;
    _notify();
    _smsCookie = '';
    _sentPhone = null;
    _sentCountry = null;
    final starting = _begin();
    final generation = _generation;
    try {
      await starting;
    } catch (error) {
      if (!_closed && generation == _generation) _fail(error);
    } finally {
      if (!_closed && generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  Future<void> sendCode(String phone, String country) async {
    if (_closed || _working || sendWaitSeconds > 0) return;
    if (_attempt == null || !sessions.ownsAttempt(_attempt!)) {
      await startPhone();
    }
    if (_closed || _attempt == null) return;
    final generation = _generation;
    _working = true;
    _error = null;
    _notify();
    try {
      _smsCookie = await _withVerification<String>(
        generation,
        (cookie) => client.sendCode(
          phone,
          country,
          sessions.deviceId,
          cookie: cookie,
          isActive: () => _active(generation),
        ),
      );
      if (!_active(generation)) return;
      _sentPhone = phone.trim();
      _sentCountry = country.trim();
      _sendAgainAt = _now().add(const Duration(seconds: 60));
      _countdown?.cancel();
      _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_closed || sendWaitSeconds == 0) timer.cancel();
        _notify();
      });
    } catch (error) {
      if (_active(generation)) _fail(error);
    } finally {
      if (!_closed && generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  Future<void> loginPhone(String phone, String country, String code) async {
    if (_closed || _working || _attempt == null) return;
    if (phone.trim() != _sentPhone || country.trim() != _sentCountry) {
      _error = '请先为当前手机号获取验证码。';
      _notify();
      return;
    }
    final generation = _generation;
    _working = true;
    _error = null;
    _notify();
    try {
      final credential = await _withVerification<QqCredential>(
        generation,
        (cookie) => client.loginSms(
          phone,
          code,
          sessions.deviceId,
          cookie: cookie,
          isActive: () => _active(generation),
        ),
      );
      await _finish(generation, credential);
    } catch (error) {
      if (_active(generation)) _fail(error);
    } finally {
      if (!_closed && generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  Future<T> _withVerification<T>(
    int generation,
    Future<T> Function(String) request,
  ) async {
    try {
      return await request(_smsCookie);
    } on QqVerificationRequired catch (error) {
      if (!_active(generation)) {
        throw const QqAuthException(QqAuthErrorKind.cancelled);
      }
      _status = QqLoginUiStatus.verifying;
      _notify();
      final result = await verify(error.challenge);
      if (!_active(generation) || result == null) {
        throw const QqAuthException(QqAuthErrorKind.cancelled);
      }
      _smsCookie = mergeQqCookies(error.challenge.cookie, result.cookie);
      _status = QqLoginUiStatus.idle;
      return request(_smsCookie);
    }
  }

  Future<void> _finish(int generation, QqCredential credential) async {
    if (!_active(generation)) return;
    final saved = await sessions.completeLogin(_attempt!, credential);
    if (!_closed && generation == _generation && saved) {
      _poll?.cancel();
      _countdown?.cancel();
      _status = QqLoginUiStatus.success;
      _error = null;
      _notify();
    }
  }

  void _fail(Object error) {
    _status = QqLoginUiStatus.failed;
    _error = error is QqAuthException || error is QqVerificationRequired
        ? error.toString()
        : '登录未完成，请重试。';
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _poll?.cancel();
    _countdown?.cancel();
    final attempt = _attempt;
    if (attempt != null) {
      unawaited(sessions.cancelLogin(attempt).catchError((Object _) {}));
    }
    super.dispose();
  }
}

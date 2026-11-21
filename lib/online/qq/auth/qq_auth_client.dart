import 'dart:convert';
import 'dart:math';

import '../../network/qq_account_transport.dart';
import 'qq_auth_error.dart';
import 'qq_credential.dart';
import 'qq_login_protocol.dart';

/// Explicit login protocols. It owns only the cookies of each active attempt.
class QqAuthClient {
  QqAuthClient({QqAccountTransport? transport, DateTime Function()? now})
    : _transport = transport ?? IoQqAccountTransport(),
      _now = now ?? DateTime.now;
  final QqAccountTransport _transport;
  final DateTime Function() _now;
  bool _closed = false;

  void _active(bool Function() isActive) {
    if (_closed || !isActive()) {
      throw const QqAuthException(QqAuthErrorKind.cancelled);
    }
  }

  Future<QqQrChallenge> createQr(
    QqQrMethod method, {
    required bool Function() isActive,
  }) async {
    _active(isActive);
    if (method == QqQrMethod.qq) {
      final response = await _send(
        QqAccountRequest(
          uri: Uri.https('ssl.ptlogin2.qq.com', '/ptqrshow', {
            'appid': '716027609',
            'e': '2',
            'l': 'M',
            's': '3',
            'd': '72',
            'v': '4',
            't': '${_now().millisecondsSinceEpoch}',
            'daid': '383',
            'pt_3rd_aid': '100497308',
            'u1': 'https://graph.qq.com/oauth2.0/login_jump',
          }),
          referer: 'https://xui.ptlogin2.qq.com/',
        ),
        isActive,
      );
      final qrsig = qqCookieValues(response.cookie)['qrsig'];
      if (qrsig == null || !validQrImage(response.bytes)) {
        throw const QqAuthException(QqAuthErrorKind.malformed);
      }
      return QqQrChallenge(
        key: qrsig,
        image: response.bytes,
        method: method,
        cookie: 'qrsig=$qrsig',
      );
    }
    final page = await _send(
      QqAccountRequest(
        uri: Uri.https('open.weixin.qq.com', '/connect/qrconnect', {
          'appid': 'wx48db31d50e334801',
          'redirect_uri': 'https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https://y.qq.com/',
          'response_type': 'code',
          'scope': 'snsapi_login',
          'state': _nonce(),
          'href': 'https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect',
        }),
        referer: 'https://open.weixin.qq.com/',
      ),
      isActive,
    );
    final uuid =
        RegExp(r'(?:[?&]|&amp;)uuid=([A-Za-z0-9_-]+)')
            .firstMatch(page.text)
            ?.group(1) ??
        RegExp(r'/connect/qrcode/([A-Za-z0-9_-]+)')
            .firstMatch(page.text)
            ?.group(1);
    if (uuid == null) throw const QqAuthException(QqAuthErrorKind.malformed);
    final image = await _send(
      QqAccountRequest(
        uri: Uri.https('open.weixin.qq.com', '/connect/qrcode/$uuid'),
        cookie: page.cookie,
        referer: 'https://open.weixin.qq.com/',
      ),
      isActive,
    );
    if (!validQrImage(image.bytes)) {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
    return QqQrChallenge(
      key: uuid,
      image: image.bytes,
      method: method,
      cookie: mergeQqCookies(page.cookie, image.cookie),
    );
  }

  Future<QqQrResult> checkQr(
    QqQrChallenge challenge,
    String deviceId, {
    required bool Function() isActive,
  }) async {
    _active(isActive);
    if (challenge.method == QqQrMethod.wechat) {
      final response = await _send(
        QqAccountRequest(
          uri: Uri.https('lp.open.weixin.qq.com', '/connect/l/qrconnect', {
            'uuid': challenge.key,
            '_': '${_now().millisecondsSinceEpoch}',
          }),
          referer: 'https://open.weixin.qq.com/',
        ),
        isActive,
      );
      final status = int.tryParse(
        RegExp(r'window\.wx_errcode\s*=\s*(\d+)')
                .firstMatch(response.text)
                ?.group(1) ??
            '',
      );
      if (status == null) {
        throw const QqAuthException(QqAuthErrorKind.malformed);
      }
      final updated = challenge.withCookies(
        mergeQqCookies(challenge.cookie, response.cookie),
      );
      if (status != 405) {
        return QqQrResult(
          status: switch (status) {
            408 => QqQrStatus.waitingScan,
            404 => QqQrStatus.waitingConfirm,
            402 => QqQrStatus.expired,
            _ => QqQrStatus.failed,
          },
          challenge: updated,
        );
      }
      final code = RegExp('window\\.wx_code\\s*=\\s*[\'"]([A-Za-z0-9_-]+)[\'"]')
          .firstMatch(response.text)
          ?.group(1);
      if (code == null) throw const QqAuthException(QqAuthErrorKind.malformed);
      final credential = await _exchange(code, deviceId, updated, isActive);
      return QqQrResult(
        status: QqQrStatus.success,
        challenge: updated,
        credential: credential,
      );
    }
    final response = await _send(
      QqAccountRequest(
        uri: Uri.https('ssl.ptlogin2.qq.com', '/ptqrlogin', {
          'u1': 'https://graph.qq.com/oauth2.0/login_jump',
          'ptqrtoken': '${qqQrToken(challenge.key)}',
          'ptredirect': '0',
          'h': '1',
          't': '1',
          'g': '1',
          'from_ui': '1',
          'ptlang': '2052',
          'action': '0-0-${_now().millisecondsSinceEpoch}',
          'js_ver': '20102616',
          'js_type': '1',
          'pt_uistyle': '40',
          'aid': '716027609',
          'daid': '383',
          'pt_3rd_aid': '100497308',
          'has_onekey': '1',
        }),
        cookie: challenge.cookie,
        referer: 'https://xui.ptlogin2.qq.com/',
      ),
      isActive,
    );
    final (code, redirect) = parseQqQrCallback(response.text);
    final updated = challenge.withCookies(
      mergeQqCookies(challenge.cookie, response.cookie),
    );
    if (code != 0) {
      return QqQrResult(
        status: switch (code) {
          66 => QqQrStatus.waitingScan,
          67 => QqQrStatus.waitingConfirm,
          65 => QqQrStatus.expired,
          _ => QqQrStatus.failed,
        },
        challenge: updated,
      );
    }
    final signature = requireQqRedirect(redirect, {
      'ssl.ptlogin2.qq.com',
      'ssl.ptlogin2.graph.qq.com',
    }, '/check_sig');
    final signed = await _send(
      QqAccountRequest(
        uri: signature,
        cookie: updated.cookie,
        referer: 'https://xui.ptlogin2.qq.com/',
      ),
      isActive,
      redirect: true,
    );
    final cookies = mergeQqCookies(updated.cookie, signed.cookie);
    final pSkey = qqCookieValues(cookies)['p_skey'];
    if (pSkey == null) throw const QqAuthException(QqAuthErrorKind.expired);
    final jump = signed.location == null
        ? Uri.https('graph.qq.com', '/oauth2.0/login_jump')
        : requireQqRedirect(signed.location!, {
            'graph.qq.com',
          }, '/oauth2.0/login_jump');
    await _send(
      QqAccountRequest(
        uri: jump,
        cookie: cookies,
        referer: 'https://graph.qq.com/oauth2.0/login_jump',
      ),
      isActive,
      redirect: true,
    );
    final state = _nonce();
    final authorized = await _send(
      QqAccountRequest(
        uri: Uri.https('graph.qq.com', '/oauth2.0/authorize'),
        cookie: cookies,
        referer: 'https://graph.qq.com/oauth2.0/login_jump',
        form: {
          'response_type': 'code',
          'client_id': '100497308',
          'redirect_uri': 'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/',
          'scope': 'get_user_info,get_app_friends',
          'state': state,
          'switch': '',
          'from_ptlogin': '1',
          'src': '1',
          'update_auth': '1',
          'openapi': '1010_1030',
          'g_tk': '${qqQrToken(pSkey, seed: 5381)}',
          'auth_time': '${_now().millisecondsSinceEpoch}',
          'ui': _nonce(),
        },
      ),
      isActive,
      redirect: true,
    );
    final authCode = qqAuthorizationCode(authorized.location ?? '', state);
    final credential = await _exchange(authCode, deviceId, updated, isActive);
    return QqQrResult(
      status: QqQrStatus.success,
      challenge: updated,
      credential: credential,
    );
  }

  Future<QqCredential> _exchange(
    String code,
    String deviceId,
    QqQrChallenge challenge,
    bool Function() active,
  ) async {
    final wechat = challenge.method == QqQrMethod.wechat;
    final response = await _send(
      QqAccountRequest(
        uri: Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
        cookie: challenge.verificationCookie,
        jsonBody: {
          'comm': wechat
              ? ({...qqAndroidLoginComm(deviceId, login: true, loginType: 1)}
                  ..remove('tmeLoginMethod'))
              : {'g_tk': 5381, 'platform': 'yqq', 'ct': 24, 'cv': 0},
          'qrLogin': {
            'module': wechat
                ? 'music.login.LoginServer'
                : 'QQConnectLogin.LoginServer',
            'method': wechat ? 'Login' : 'QQLogin',
            'param': {
              'code': code,
              if (wechat) 'strAppid': 'wx48db31d50e334801',
            },
          },
        },
      ),
      active,
    );
    final root = _json(response);
    checkQqLoginResult(root, challenge.verificationCookie);
    final result = _object(root['qrLogin']);
    final cookie = mergeQqCookies(
      challenge.verificationCookie,
      response.cookie,
    );
    checkQqLoginResult(result, cookie);
    return QqCredential.fromLoginData(
      _object(result['data']),
      cookie: cookie,
      loginType: wechat ? 1 : 2,
    );
  }

  Future<String> sendCode(
    String phone,
    String country,
    String deviceId, {
    String cookie = '',
    required bool Function() isActive,
  }) async {
    final response = await _phone(
      'SendPhoneAuthCode',
      {
        'tmeAppid': 'qqmusic',
        'areaCode': _country(country),
        'phoneNo': _phoneNumber(phone),
      },
      deviceId,
      cookie,
      isActive,
      login: false,
    );
    return response.$2;
  }

  Future<QqCredential> loginSms(
    String phone,
    String code,
    String deviceId, {
    String cookie = '',
    required bool Function() isActive,
  }) async {
    if (!RegExp(r'^\d{4,10}$').hasMatch(code.trim())) {
      throw const QqAuthException(QqAuthErrorKind.invalidCode);
    }
    final response = await _phone(
      'Login',
      {'phoneNo': _phoneNumber(phone), 'code': code.trim(), 'loginMode': 1},
      deviceId,
      cookie,
      isActive,
      login: true,
    );
    return QqCredential.fromLoginData(
      _object(response.$1['data']),
      cookie: response.$2,
    );
  }

  Future<QqCredential> refresh(
    QqCredential previous,
    String deviceId, {
    required bool Function() isActive,
  }) async {
    final values = previous.values;
    final response = await _phone(
      'Login',
      {
        'openid': values['openid'] ?? '',
        'access_token': values['access_token'] ?? '',
        'refresh_token': values['refresh_token'] ?? '',
        'expired_in': int.tryParse(values['expired_at'] ?? '') ?? 0,
        'str_musicid': values['str_musicid'] ?? previous.accountId,
        'musicid': int.parse(previous.accountId),
        'musickey': previous.musicKey,
        'unionid': values['unionid'] ?? '',
        'refresh_key': values['refresh_key'] ?? '',
        'loginMode': 2,
      },
      deviceId,
      previous.cookie,
      isActive,
      login: true,
      previous: previous,
    );
    final data = _object(response.$1['data']);
    data.putIfAbsent('musicid', () => previous.accountId);
    final updated = QqCredential.fromLoginData(
      data,
      cookie: response.$2,
      loginType: previous.loginType,
    );
    if (updated.accountId != previous.accountId) {
      throw const QqAuthException(QqAuthErrorKind.rejected);
    }
    return updated;
  }

  Future<(Map<String, Object?>, String)> _phone(
    String method,
    Map<String, Object?> params,
    String deviceId,
    String cookie,
    bool Function() active, {
    required bool login,
    QqCredential? previous,
  }) async {
    final response = await _send(
      QqAccountRequest(
        uri: Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
        cookie: cookie,
        jsonBody: {
          'comm': {
            ...qqAndroidLoginComm(
              deviceId,
              login: login,
              loginType: previous?.loginType ?? 0,
            ),
            if (previous != null) 'qq': previous.accountId,
            if (previous != null) 'authst': previous.musicKey,
          },
          'phoneLogin': {
            'module': 'music.login.LoginServer',
            'method': method,
            'param': params,
          },
        },
      ),
      active,
    );
    final merged = mergeQqCookies(cookie, response.cookie);
    final root = _json(response);
    checkQqLoginResult(root, merged);
    final result = _object(root['phoneLogin']);
    checkQqLoginResult(result, merged);
    return (result, merged);
  }

  Future<QqAccountResponse> _send(
    QqAccountRequest request,
    bool Function() active, {
    bool redirect = false,
  }) async {
    _active(active);
    final response = await _transport.send(request);
    _active(active);
    if (response.status == 429 || response.status == 503) {
      throw const QqAuthException(QqAuthErrorKind.rateLimited);
    }
    if (response.status != 200 &&
        !(redirect && response.status >= 300 && response.status < 400)) {
      throw const QqAuthException(QqAuthErrorKind.rejected);
    }
    return response;
  }

  Map<String, Object?> _json(QqAccountResponse response) {
    try {
      return _object(jsonDecode(response.text));
    } on FormatException {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
  }

  Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
    return value;
  }

  String _phoneNumber(String value) {
    final text = value.trim();
    if (!RegExp(r'^\d{6,20}$').hasMatch(text)) {
      throw const QqAuthException(QqAuthErrorKind.rejected);
    }
    return text;
  }

  String _country(String value) {
    final text = value.trim().replaceFirst('+', '');
    if (!RegExp(r'^\d{1,4}$').hasMatch(text)) {
      throw const QqAuthException(QqAuthErrorKind.rejected);
    }
    return text;
  }

  String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _transport.close();
  }
}

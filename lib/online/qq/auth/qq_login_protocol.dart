import 'dart:typed_data';

import 'qq_auth_error.dart';
import 'qq_credential.dart';

const qqBrowserUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Motif/0.1';
const qqWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
const qqMusicUserAgent = 'QQMusic 14090008(android 14)';
const qqSearchUserAgent = 'QQMusic 20050009(android 14)';
const qqPlaylistUserAgent = 'QQMusic 2005000982(android 14)';

String qqLoginPhoneNumber(String value) {
  final text = value.trim();
  if (!RegExp(r'^\d{6,20}$').hasMatch(text)) {
    throw const QqAuthException(QqAuthErrorKind.rejected);
  }
  return text;
}

String qqLoginCountryCode(String value) {
  final text = value.trim().replaceFirst('+', '');
  if (!RegExp(r'^\d{1,4}$').hasMatch(text)) {
    throw const QqAuthException(QqAuthErrorKind.rejected);
  }
  return text;
}

enum QqQrMethod { qq, wechat }

enum QqQrStatus { waitingScan, waitingConfirm, expired, failed, success }

class QqQrChallenge {
  const QqQrChallenge({
    required this.key,
    required this.image,
    required this.method,
    this.cookie = '',
    this.verificationCookie = '',
  });
  final String key;
  final Uint8List image;
  final QqQrMethod method;
  final String cookie;
  final String verificationCookie;
  String get scanMessage => method == QqQrMethod.qq ? '使用手机 QQ 扫码' : '使用微信扫码';
  QqQrChallenge withCookies(String cookie, {String? verificationCookie}) =>
      QqQrChallenge(
        key: key,
        image: image,
        method: method,
        cookie: cookie,
        verificationCookie: verificationCookie ?? this.verificationCookie,
      );
  @override
  String toString() => 'QqQrChallenge(redacted)';
}

class QqQrResult {
  const QqQrResult({
    required this.status,
    required this.challenge,
    this.credential,
  });
  final QqQrStatus status;
  final QqQrChallenge challenge;
  final QqCredential? credential;
}

class QqSecurityChallenge {
  const QqSecurityChallenge({required this.uri, required this.cookie});
  final Uri uri;
  final String cookie;
  @override
  String toString() => 'QqSecurityChallenge(redacted)';
}

class QqVerificationRequired implements Exception {
  const QqVerificationRequired(this.challenge);
  final QqSecurityChallenge challenge;
  @override
  String toString() => '请完成 QQ 音乐安全验证。';
}

class QqVerificationResult {
  const QqVerificationResult({required this.cookie});
  final String cookie;
  @override
  String toString() => 'QqVerificationResult(redacted)';
}

typedef QqVerify = Future<QqVerificationResult?> Function(
  QqSecurityChallenge challenge,
);

Map<String, Object?> qqAndroidLoginComm(
  String deviceId, {
  bool login = false,
  int loginType = 0,
}) => {
  'ct': 11,
  'cv': 14090008,
  'v': 14090008,
  'chid': '10003505',
  'tmeAppID': 'qqmusic',
  'tmeLoginMethod': 3,
  'QIMEI': '',
  'QIMEI36': '',
  'OpenUDID': deviceId,
  'OpenUDID2': deviceId,
  'udid': deviceId,
  'aid': deviceId,
  'os_ver': '14',
  'phonetype': 'Motif',
  'devicelevel': '34',
  'newdevicelevel': '34',
  'rom': 'Motif',
  if (login) 'tmeLoginType': loginType,
};

Map<String, Object?> qqPlaybackComm(QqCredential? credential) => {
  'ct': 11,
  'cv': 14090008,
  'v': 14090008,
  'chid': '10003505',
  'qq': credential?.accountId ?? '',
  'authst': credential?.musicKey ?? '',
  'tmeAppID': 'qqmusic',
  'tmeLoginType': credential?.loginType ?? 2,
  'format': 'json',
};

Map<String, Object?> qqPersonalizedComm(QqCredential credential) => {
  'uin': credential.accountId,
  'format': 'json',
  'ct': 19,
  'cv': 0,
  'authst': credential.musicKey,
};

int qqQrToken(String value, {int seed = 0}) {
  var result = seed;
  for (final char in value.codeUnits) {
    result = ((result * 33) + char) & 0x7fffffff;
  }
  return result;
}

(int, String) parseQqQrCallback(String text) {
  if (text.length > 32768) {
    throw const QqAuthException(QqAuthErrorKind.malformed);
  }
  final callback = RegExp(
    r"ptuiCB\((.*?)\)\s*;?",
    dotAll: true,
  ).firstMatch(text);
  if (callback == null) throw const QqAuthException(QqAuthErrorKind.malformed);
  final args = RegExp(r"'((?:\\.|[^'\\])*)'")
      .allMatches(callback.group(1)!)
      .map(
        (match) => match
            .group(1)!
            .replaceAll(r"\'", "'")
            .replaceAll(r'\/', '/')
            .replaceAll(r'\\', r'\'),
      )
      .toList();
  final code = args.isEmpty ? null : int.tryParse(args.first);
  if (code == null || args.length < 3) {
    throw const QqAuthException(QqAuthErrorKind.malformed);
  }
  return (code, args[2]);
}

bool validQrImage(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes.length <= 524288 &&
    ([
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ].asMap().entries.every((entry) => bytes[entry.key] == entry.value) ||
        (bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255) ||
        (bytes[0] == 71 && bytes[1] == 73 && bytes[2] == 70));

Uri requireQqRedirect(String value, Set<String> hosts, String path) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !hosts.contains(uri.host) ||
      uri.path != path) {
    throw const QqAuthException(QqAuthErrorKind.rejected);
  }
  return uri;
}

Uri qqOAuthJumpUri(String? location) {
  final base = Uri.https('graph.qq.com', '/oauth2.0/login_jump');
  var uri = base.resolve(location?.trim().isNotEmpty == true ? location! : '');
  // Legacy graph redirects can advertise HTTP. Request the same endpoint over
  // HTTPS; OAuth cookies must never be sent to a plaintext connection.
  if (uri.scheme == 'http' && uri.port == 80) {
    uri = uri.replace(scheme: 'https', port: 443);
  }
  return requireQqRedirect(uri.toString(), {
    'graph.qq.com',
  }, '/oauth2.0/login_jump');
}

String qqAuthorizationCode(String value, String expectedState) {
  final uri = qqAuthorizationRedirectUri(
    value,
    from: Uri.https('y.qq.com', '/portal/wx_redirect.html'),
    expectedState: expectedState,
  );
  if (uri.host != 'y.qq.com') {
    throw const QqAuthException(
      QqAuthErrorKind.rejected,
      reason: QqAuthReason.redirectInvalid,
    );
  }
  final codes = uri.queryParametersAll['code'];
  if (codes == null ||
      codes.length != 1 ||
      codes.single.isEmpty ||
      codes.single.length > 2048) {
    throw const QqAuthException(
      QqAuthErrorKind.malformed,
      reason: QqAuthReason.codeMissing,
    );
  }
  return codes.single;
}

Uri qqAuthorizationRedirectUri(
  String value, {
  required Uri from,
  required String expectedState,
}) {
  if (value.trim().isEmpty || value.length > 32768) {
    throw const QqAuthException(
      QqAuthErrorKind.rejected,
      reason: QqAuthReason.redirectMissing,
    );
  }
  var uri = from.resolve(value.trim()).removeFragment();
  if (uri.scheme == 'http' && uri.port == 80) {
    uri = uri.replace(scheme: 'https', port: 443);
  }
  final portal =
      uri.host == 'y.qq.com' && uri.path == '/portal/wx_redirect.html';
  final graph =
      uri.host == 'graph.qq.com' &&
      uri.path.startsWith('/oauth2.0/') &&
      uri.pathSegments.every(
        (segment) =>
            segment != '.' && segment != '..' && !segment.contains('/'),
      );
  if (uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      (!portal && !graph)) {
    throw const QqAuthException(
      QqAuthErrorKind.rejected,
      reason: QqAuthReason.redirectInvalid,
    );
  }
  final states = uri.queryParametersAll['state'];
  if (states != null &&
      (states.length != 1 ||
          states.single.isNotEmpty && states.single != expectedState)) {
    throw const QqAuthException(
      QqAuthErrorKind.rejected,
      reason: QqAuthReason.stateMismatch,
    );
  }
  return uri;
}

bool isQqVerificationUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (uri.host == 'qq.com' ||
        uri.host.endsWith('.qq.com') ||
        uri.host == 'tencent.com' ||
        uri.host.endsWith('.tencent.com') ||
        uri.host == 'qcloud.com' ||
        uri.host.endsWith('.qcloud.com'));

bool isQqVerificationClose(Uri uri) =>
    uri.scheme == 'qqmusic' &&
    uri.host == 'qq.com' &&
    {
      'closeWebView',
      'closeWebview',
      'finishWebView',
    }.contains(uri.pathSegments.lastOrNull);

QqSecurityChallenge? qqRequestSecurityChallenge(
  Map<String, Object?> result,
  String cookie, {
  required int code,
}) {
  final fields = switch (code) {
    20276 => const ['securityURL', 'securityUrl'],
    2001 => const ['feedbackURL', 'feedbackUrl'],
    104009 => const ['validURL', 'validUrl'],
    _ => const <String>[],
  };
  var current = result;
  for (var depth = 0; depth < 4 && fields.isNotEmpty; depth++) {
    for (final field in fields) {
      final value = current[field];
      var uri = value is String ? Uri.tryParse(value) : null;
      if (uri == null || !isQqVerificationUri(uri)) continue;
      if (code == 104009 && uri.queryParameters['_vkey_verify'] != '1') {
        uri = uri.replace(
          query: '${uri.query}${uri.query.isEmpty ? '' : '&'}_vkey_verify=1',
        );
      }
      return QqSecurityChallenge(uri: uri, cookie: cookie);
    }
    final data = current['data'];
    if (data is! Map<String, Object?>) break;
    current = data;
  }
  return null;
}

void checkQqLoginResult(Map<String, Object?> result, String cookie) {
  final code = result['code'] is int
      ? result['code'] as int
      : int.tryParse('${result['code']}');
  if (code == null) throw const QqAuthException(QqAuthErrorKind.malformed);
  final challenge = qqRequestSecurityChallenge(result, cookie, code: code);
  if (challenge != null) {
    throw QqVerificationRequired(challenge);
  }
  if (code != 0) throw qqLoginFailure(code);
}

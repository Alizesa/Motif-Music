import 'dart:convert';

import 'qq_auth_error.dart';

String? normalizeQqAccountId(Object? value) {
  if (value is! String && value is! int) return null;
  final text = value
      .toString()
      .trim()
      .replaceFirst(RegExp(r'^o'), '')
      .replaceFirst(RegExp(r'^0+'), '');
  return RegExp(r'^\d{1,20}$').hasMatch(text) ? text : null;
}

Map<String, String> qqCookieValues(String value) {
  if (value.length > 32768 || RegExp(r'[\r\n\x00]').hasMatch(value)) {
    throw const QqAuthException(QqAuthErrorKind.malformed);
  }
  final result = <String, String>{};
  for (final part in value.split(';')) {
    final separator = part.indexOf('=');
    if (separator <= 0) continue;
    final name = part.substring(0, separator).trim();
    final text = part.substring(separator + 1).trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(name) ||
        text.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(text)) {
      continue;
    }
    result[name] = text;
  }
  return result;
}

String qqCookieHeader(Map<String, String> values) =>
    values.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

String mergeQqCookies(String first, String second) =>
    qqCookieHeader({...qqCookieValues(first), ...qqCookieValues(second)});

class QqAccount {
  const QqAccount({required this.id, required this.name, this.avatar});
  final String id;
  final String name;
  final Uri? avatar;
}

class QqCredential {
  QqCredential({required this.account, required this.cookie}) {
    final values = qqCookieValues(cookie);
    if (account.id != accountIdFromCookies(values) ||
        musicKeyFromCookies(values).isEmpty) {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
  }

  final QqAccount account;
  final String cookie;
  Map<String, String> get values => qqCookieValues(cookie);
  String get accountId => account.id;
  String get musicKey => musicKeyFromCookies(values);
  int get loginType =>
      int.tryParse(values['loginType'] ?? '') ??
      (musicKey.startsWith('W_X') ? 1 : 2);

  DateTime? get expiresAt {
    final expiry = int.tryParse(values['expired_at'] ?? '');
    if (expiry != null && expiry > 1000000000 && expiry < 100000000000) {
      return DateTime.fromMillisecondsSinceEpoch(expiry * 1000, isUtc: true);
    }
    final created = int.tryParse(values['musickeyCreateTime'] ?? '');
    final lifetime = int.tryParse(values['keyExpiresIn'] ?? '');
    if (created != null &&
        created > 1000000000 &&
        lifetime != null &&
        lifetime > 0 &&
        lifetime < 315360000) {
      return DateTime.fromMillisecondsSinceEpoch(
        (created + lifetime) * 1000,
        isUtc: true,
      );
    }
    return null;
  }

  Map<String, Object?> toSecretJson() => {
    'id': account.id,
    'name': account.name,
    'avatar': account.avatar?.toString(),
    'cookie': cookie,
  };

  factory QqCredential.fromSecretJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['cookie'] is! String) {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
    return QqCredential(
      account: QqAccount(
        id: value['id']! as String,
        name: value['name']! as String,
        avatar: qqAvatar(value['avatar']),
      ),
      cookie: value['cookie']! as String,
    );
  }

  factory QqCredential.fromLoginData(
    Map<String, Object?> data, {
    String cookie = '',
    int? loginType,
  }) {
    final id = ['musicid', 'str_musicid', 'musicId', 'userid', 'user_id', 'uin']
        .map((key) => normalizeQqAccountId(data[key]))
        .whereType<String>()
        .firstOrNull;
    final key =
        ['musickey', 'music_key', 'qqmusic_key', 'qm_keyst', 'strMusicKey']
            .map((key) => data[key])
            .whereType<String>()
            .where((value) => value.isNotEmpty)
            .firstOrNull;
    if (id == null || key == null) {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
    const allowed = [
      'openid',
      'refresh_token',
      'access_token',
      'expired_at',
      'musicid',
      'str_musicid',
      'musickey',
      'unionid',
      'refresh_key',
      'musickeyCreateTime',
      'keyExpiresIn',
      'first_login',
      'bindAccountType',
      'needRefreshKeyIn',
      'encryptUin',
      'loginType',
    ];
    if (RegExp(r'[;\x00-\x20\x7f]').hasMatch(key)) {
      throw const QqAuthException(QqAuthErrorKind.malformed);
    }
    final values = <String, String>{
      ...qqCookieValues(cookie),
      for (final name in allowed)
        if (data[name] != null && data[name].toString().isNotEmpty)
          name: data[name].toString(),
      'musicid': id,
      'musickey': key,
      'uin': 'o${id.padLeft(10, '0')}',
      'qqmusic_uin': id,
      'qqmusic_key': key,
      'qm_keyst': key,
      'authst': key,
      if (loginType != null) 'loginType': '$loginType',
    };
    final name = ['nick', 'nickname', 'nickName', 'name']
        .map((field) => data[field])
        .whereType<String>()
        .where((name) => name.trim().isNotEmpty)
        .firstOrNull;
    final avatar = [
      'avatar',
      'avatarUrl',
      'head',
      'headPic',
      'headurl',
    ].map((field) => qqAvatar(data[field])).whereType<Uri>().firstOrNull;
    final displayName = name?.trim() ?? 'QQ 用户';
    return QqCredential(
      account: QqAccount(
        id: id,
        name: displayName.length > 512
            ? displayName.substring(0, 512)
            : displayName,
        avatar: avatar,
      ),
      cookie: qqCookieHeader(values),
    );
  }

  @override
  String toString() => 'QqCredential(redacted)';
}

String? accountIdFromCookies(Map<String, String> values) =>
    [
          'str_musicid',
          'musicid',
          'qqmusic_uin',
          'userid',
          'user_id',
          'uin',
          'wxuin',
          'ptui_loginuin',
          'luin',
          'pt2gguin',
          'superuin',
          'p_uin',
        ]
        .map((field) => normalizeQqAccountId(values[field]))
        .whereType<String>()
        .firstOrNull;

String musicKeyFromCookies(Map<String, String> values) =>
    ['musickey', 'qqmusic_key', 'qm_keyst', 'authst']
        .map((field) => values[field])
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .firstOrNull ??
    '';

Uri? qqAvatar(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final text = value.startsWith('//') ? 'https:$value' : value;
  final uri = Uri.tryParse(text);
  return uri?.scheme == 'https' &&
          uri!.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasFragment
      ? uri
      : null;
}

abstract interface class QqCredentialVault {
  Future<String?> read();
  Future<void> write(String value);
}

String encodeQqSession(String deviceId, QqCredential? credential) =>
    jsonEncode({
      'version': 1,
      'deviceId': deviceId,
      'credential': credential?.toSecretJson(),
    });

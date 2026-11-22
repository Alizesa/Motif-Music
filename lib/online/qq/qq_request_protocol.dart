import '../domain/playback_source.dart';
import 'auth/qq_credential.dart';
import 'auth/qq_login_protocol.dart';
import 'qq_track.dart';
import 'qq_response_parser.dart';

const qqCredentialExpiredCodes = {301, 401, 1000, 104400, 104401};
const qqBusinessRateLimitCodes = {429, 100001, 104604};
const qqVerificationCodes = {2001, 20276, 104009};
const qqBlockingVkeyCodes = {
  ...qqCredentialExpiredCodes,
  ...qqBusinessRateLimitCodes,
  ...qqVerificationCodes,
};

Map<String, Object?> qqWebComm([QqCredential? credential]) => {
  'ct': 24,
  'cv': 4747474,
  'format': 'json',
  'inCharset': 'utf-8',
  'outCharset': 'utf-8',
  'notice': 0,
  'platform': 'yqq.json',
  'needNewCode': 1,
  'uin': credential?.accountId ?? '0',
};

Map<String, Object?> qqSearchComm([QqCredential? credential]) => {
  ...qqPlaybackComm(credential),
  'ct': 19,
  'cv': 1859,
  'v': 1859,
  'uin': credential?.accountId ?? '',
};

String qqSearchQuery(String query, {required int page, required int pageSize}) {
  final text = query.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty ||
      text.length > 200 ||
      page < 1 ||
      page > 100 ||
      pageSize < 1 ||
      pageSize > 30) {
    throw ArgumentError('Invalid search parameters');
  }
  return text;
}

Map<String, Object?> qqSearchParameters(String query, int page, int pageSize) =>
    {
      'query': query,
      'search_type': 0,
      'page_num': page,
      'num_per_page': pageSize,
      'sin': (page - 1) * pageSize,
      'ein': page * pageSize,
      'highlight': 0,
      'cat': 2,
      'grp': 1,
      'nqc_flag': 0,
      'remoteplace': 'txt.mqq.all',
      'multi_zhida': 0,
      'sem': 0,
    };

(String, String) _qualitySpec(OnlineQuality quality) => switch (quality) {
  OnlineQuality.standard => ('M500', 'mp3'),
  OnlineQuality.high => ('M800', 'mp3'),
  OnlineQuality.lossless => ('F000', 'flac'),
  OnlineQuality.hiRes => ('RS01', 'flac'),
};

String qqPlaybackFilename(QqTrack track, OnlineQuality quality) {
  final (prefix, extension) = _qualitySpec(quality);
  return '$prefix${track.mediaMid ?? '${track.mid}${track.mid}'}.$extension';
}

Map<String, Object?> qqPlaybackParameters(
  QqTrack track,
  OnlineQuality quality, {
  required String guid,
  required String accountId,
}) => {
  'guid': guid,
  'songmid': [track.mid],
  'songtype': [track.songType],
  'uin': accountId,
  'loginflag': 1,
  'platform': '23',
  'h5queryversion': 1,
  'nettype': '',
  'cms': 0,
  'firstlogin': 1,
  'newver': 1,
  'nohash': 0,
  'quality': _qualitySpec(quality).$1,
  'filename': [qqPlaybackFilename(track, quality)],
};

Uri? _qqStreamUri(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  final uri = parsePlaybackUri(text.startsWith('//') ? 'https:$text' : text);
  return uri?.scheme == 'http'
      ? uri!.replace(scheme: 'https', port: uri.port == 80 ? 443 : uri.port)
      : uri;
}

/// Accept only the requested file from the ticket response, including the
/// server's wifi URL and scheme-relative CDN forms. No extra ticket probes.
Uri? qqPlaybackUri(
  Map<String, Object?> data,
  QqTrack track,
  OnlineQuality quality,
) {
  final entries = data['midurlinfo'];
  if (entries is! List) return null;
  final filename = qqPlaybackFilename(track, quality);
  final servers = data['sip'] is List ? data['sip'] as List : const [];
  final bases = servers.take(10).map(_qqStreamUri).whereType<Uri>().toList()
    ..sort(
      (a, b) =>
          (a.scheme == 'https' ? 0 : 1).compareTo(b.scheme == 'https' ? 0 : 1),
    );
  for (final item in entries.take(10)) {
    if (item is! Map<String, Object?> ||
        qqInt(item['result']) != 0 ||
        item['songmid'] != null && item['songmid'] != track.mid) {
      continue;
    }
    for (final field in ['purl', 'wifiurl']) {
      final value = qqText(item[field]);
      if (value == null) continue;
      final path = Uri.tryParse(
        value.startsWith('//') ? 'https:$value' : value,
      );
      if (path == null || path.pathSegments.lastOrNull != filename) continue;
      if (path.hasScheme) {
        final direct = _qqStreamUri(value);
        if (direct != null) return direct;
      } else {
        for (final base in bases) {
          final candidate = _qqStreamUri(base.resolve(value).toString());
          if (candidate != null) return candidate;
        }
      }
    }
  }
  return null;
}

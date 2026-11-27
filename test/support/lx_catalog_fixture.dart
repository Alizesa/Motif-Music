import 'dart:convert';
import 'dart:typed_data';

import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_http_connection.dart';
import 'package:motif/online/lx/lx_music_platform.dart';
import 'package:motif/online/qq/qq_track.dart';

QqTrack catalogTrack({
  int? duration = 180000,
  String title = '曲目',
  List<String> artists = const ['甲', '乙'],
}) => QqTrack(
  mid: 'originalQQ',
  mediaMid: 'originalMedia',
  songId: 456,
  songType: 7,
  durationMs: duration,
  title: title,
  album: '专辑',
  artists: artists,
  qualitySizes: {for (final q in OnlineQuality.values) q: 4096},
);

const baseHash = '123456789abcdef0123456789abcdef0';
const losslessHash = 'fedcba9876543210fedcba9876543210';
Map<String, Object?> kwRow([Map<String, Object?> extra = const {}]) => {
  'MUSICRID': 'MUSIC_731',
  'DURATION': '181',
  'ARTIST': '乙&甲',
  'ALBUM': '专辑',
  'ALBUMID': '76',
  'SONGNAME': '曲目',
  'N_MINFO': 'level:ff,bitrate:2000,format:flac,size:24.2M;level:mp3,bitrate:128,format:mp3,size:4.2M',
  ...extra,
};
Map<String, Object?> kgRow([Map<String, Object?> extra = const {}]) => {
  'Audioid': 912,
  'Duration': 180,
  'Singers': [
    {'name': '甲'},
    {'name': '乙'},
  ],
  'AlbumName': '专辑',
  'AlbumID': 45,
  'OriSongName': '曲目',
  'Suffix': '',
  'FileSize': 65536,
  'FileHash': baseHash,
  'SQFileSize': 10485760,
  'SQFileHash': losslessHash,
  'Grp': [],
  ...extra,
};

final class CatalogFixture {
  final requests = <Uri>[];
  final bodies = <CatalogBody>[];
  final queries = <LxPlatform>[];
  Map<LxPlatform, List<Object?>> rows = {
    LxPlatform.kw: [kwRow()],
    LxPlatform.kg: [kgRow()],
  };
  var status = 200;
  Map<String, List<String>> headers = {};
  Future<void> Function(PcmCancellation)? beforeResponse;

  Future<LxWireResponse> open(
    Uri uri,
    String method,
    Map<String, String> headers,
    Uint8List? payload,
    PcmCancellation scope,
  ) async {
    if (method != 'GET' ||
        payload != null ||
        uri.scheme != 'https' ||
        headers.keys.any((k) => !{'user-agent', 'accept'}.contains(k))) {
      throw StateError('Unexpected catalog request');
    }
    scope.check();
    final platform = switch ((uri.host, uri.path)) {
      ('search.kuwo.cn', '/r.s') => LxPlatform.kw,
      ('songsearch.kugou.com', '/song_search_v2') => LxPlatform.kg,
      _ => throw StateError('Unexpected catalog destination'),
    };
    requests.add(uri);
    queries.add(platform);
    await beforeResponse?.call(scope);
    final list = rows[platform];
    final body = CatalogBody(
      utf8.encode(
        jsonEncode(
          platform == LxPlatform.kw
              ? {'TOTAL': '${list?.length}', 'abslist': list}
              : {
                  'error_code': 0,
                  'data': {'lists': list},
                },
        ),
      ),
    );
    bodies.add(body);
    return (
      status: status,
      reason: 'fixture',
      headers: this.headers,
      body: body,
    );
  }
}

final class CatalogBody implements LxWireBody {
  CatalogBody(this.data);
  final Uint8List data;
  int offset = 0;
  bool closed = false;
  @override
  Future<Uint8List> read(int maximum) async {
    if (closed) throw StateError('Closed fixture body');
    final end = (offset + maximum).clamp(offset, data.length);
    final bytes = Uint8List.sublistView(data, offset, end);
    offset = end;
    return bytes;
  }

  @override
  Future<String> readLine(int limit) =>
      throw UnsupportedError('fixture is not chunked');
  @override
  void close() {
    closed = true;
  }
}

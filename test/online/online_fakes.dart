import 'dart:convert';

import 'package:motif/online/network/qq_http_transport.dart';
import 'package:motif/online/network/request_coordinator.dart';
import 'package:motif/online/qq/qq_music_client.dart';

class TestClock {
  DateTime time = DateTime.utc(2026, 11, 21);
  final waits = <Duration>[];
  DateTime now() => time;
  void advance(Duration duration) => time = time.add(duration);
  Future<void> wait(Duration duration) async {
    waits.add(duration);
    advance(duration);
  }

  RequestCoordinator coordinator({
    int maxCacheEntries = 128,
    int maxPendingRequests = 24,
  }) => RequestCoordinator(
    now: now,
    wait: wait,
    maxCacheEntries: maxCacheEntries,
    maxPendingRequests: maxPendingRequests,
  );
}

class FakeQqTransport implements QqHttpTransport {
  final requests = <QqHttpRequest>[];
  bool closed = false;
  late Future<QqHttpResponse> Function(QqHttpRequest) reply;
  @override
  Future<QqHttpResponse> send(QqHttpRequest request) async {
    requests.add(request);
    return reply(request);
  }

  @override
  void close() => closed = true;
}

Map<String, Object?> songJson({
  String mid = 'songMid001',
  bool legacy = false,
}) => {
  if (legacy) ...{
    'songmid': mid,
    'songid': 42,
    'songname': 'Song',
    'albumname': 'Album',
    'albummid': 'album001',
    'size128': 123456,
    'size320': 234567,
    'strMediaMid': 'media001',
  } else ...{
    'mid': mid,
    'id': 42,
    'name': 'Song',
    'type': 0,
    'album': {'name': 'Album', 'mid': 'album001'},
    'file': {
      'media_mid': 'media001',
      'size_128mp3': 123456,
      'size_320mp3': 234567,
      'size_flac': 345678,
      'size_hires': 456789,
    },
  },
  'singer': [
    {'name': 'Artist', 'mid': 'artist001'},
  ],
  'interval': 180,
};

QqHttpResponse jsonResponse(
  Object body, {
  int status = 200,
  String? retryAfter,
}) => QqHttpResponse(
  statusCode: status,
  body: jsonEncode(body),
  retryAfter: retryAfter,
);

QqHttpResponse searchResponse({List<Object?>? tracks, int total = 1}) =>
    jsonResponse({
      'code': 0,
      'SONG': {
        'code': 0,
        'data': {
          'body': {
            'song': {
              'list': tracks ?? [songJson()],
            },
          },
          'meta': {'sum': total},
        },
      },
    });

QqHttpResponse moduleResponse(Object data, {int code = 0}) => jsonResponse({
  'code': 0,
  'req_1': {'code': code, 'data': data},
});

QqMusicClient testClient(FakeQqTransport transport, TestClock clock) =>
    QqMusicClient(
      transport: transport,
      coordinator: clock.coordinator(),
      now: clock.now,
      guid: '1234567890',
    );

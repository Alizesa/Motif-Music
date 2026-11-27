import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/online/domain/download_source.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/lx/lx_music_platform.dart';
import 'package:motif/online/lx/lx_ordered_source.dart';
import 'package:motif/online/qq/qq_track.dart';

class OrderedScriptStub extends Fake implements OrderedLxSource {
  OrderedScriptStub(this.sourceId);
  @override
  final String sourceId;
  bool unavailable = false;
  int transfers = 0;
  @override
  Set<OnlineQuality> get downloadQualities => {OnlineQuality.high};
  @override
  bool supports(LxPlatform platform, OnlineQuality quality) =>
      platform == LxPlatform.tx && downloadQualities.contains(quality);
  @override
  Future<String> transfer(
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
    DiagnosticTrace? trace,
    LxPlatform? onlyPlatform,
  }) async {
    transfers++;
    cancellation.check();
    if (unavailable) throw const OnlineException(OnlineErrorKind.unavailable);
    onTotal(4);
    await write(Uint8List.fromList([1, 2, 3, 4]));
    return 'mp3';
  }

  @override
  void close() {}
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/downloads/download_controller.dart';
import 'package:motif/downloads/download_destination.dart';
import 'package:motif/features/downloads/download_page.dart';
import 'package:motif/online/domain/download_source.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/qq/qq_track.dart';

import '../online/playback_fakes.dart';

void main() {
  testWidgets(
    'download sheet requires a directory, then starts the selected source and quality',
    (tester) async {
      final source = _Source();
      final destination = _Destination();
      final controller = DownloadController(
        sources: MusicSourceRegistry(
          qq: FakePlaybackSource('qq'),
          thirdPartySources: [
            MusicSourceRegistration(name: 'Test source', resolver: source),
          ],
        ),
        destination: destination,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  showTrackDownloadSheet(
                    context,
                    controller: controller,
                    track: playbackTrack(1),
                    preferredSourceId: 'script',
                    quality: OnlineQuality.high,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始下载'))
            .onPressed,
        isNull,
      );
      expect(source.transfers, 0);
      await tester.tap(find.text('选择保存目录'));
      await tester.pumpAndSettle();
      expect(find.text('Selected folder'), findsOneWidget);
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
      expect(source.transfers, 1);
      expect(controller.tasks.single.quality, OnlineQuality.high);
      expect(controller.tasks.single.status, DownloadStatus.completed);
      expect(destination.aborted, 0);
    },
  );

  testWidgets(
    'download management cancels active work and retries without another song selection',
    (tester) async {
      final source = _Source()..gate = Completer<void>();
      final destination = _Destination();
      final controller = DownloadController(
        sources: MusicSourceRegistry(
          qq: FakePlaybackSource('qq'),
          thirdPartySources: [
            MusicSourceRegistration(name: 'Test source', resolver: source),
          ],
        ),
        destination: destination,
      );
      addTearDown(controller.dispose);
      await controller.chooseDirectory();
      unawaited(
        controller.start(playbackTrack(2), 'script', OnlineQuality.standard),
      );
      await tester.pumpWidget(
        MaterialApp(home: DownloadPage(controller: controller)),
      );
      await tester.pump();
      await tester.tap(find.text('取消下载'));
      await tester.pumpAndSettle();
      expect(find.text('已取消'), findsOneWidget);
      final cancelled = controller.tasks.single;
      expect(destination.aborted, 1);
      source.gate = null;
      await tester.tap(find.text('重新下载'));
      await tester.pumpAndSettle();
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('已取消'), findsNothing);
      expect(controller.tasks, [same(cancelled)]);
      expect(source.transfers, 2);
    },
  );
}

class _Source extends FakePlaybackSource implements TrackDownloadSource {
  _Source() : super('script');
  int transfers = 0;
  Completer<void>? gate;
  @override
  Set<OnlineQuality> get downloadQualities => {
    OnlineQuality.standard,
    OnlineQuality.high,
  };
  @override
  Future<String> transfer(
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
  }) async {
    transfers++;
    if (gate != null) await cancellation.until(gate!.future);
    onTotal(4);
    await write(Uint8List.fromList([1, 2, 3, 4]));
    return 'mp3';
  }
}

class _Destination implements DownloadDestination {
  int aborted = 0;
  @override
  Future<DownloadDirectory?> chooseDirectory() async =>
      DownloadDirectory(Uri.parse('file:///selected'), 'Selected folder');
  @override
  Future<DownloadWriter> create(DownloadDirectory directory) async =>
      _Writer(this);
}

class _Writer implements DownloadWriter {
  _Writer(this.destination);
  final _Destination destination;
  @override
  Future<void> write(Uint8List bytes) async {}
  @override
  Future<void> abort() async {
    destination.aborted++;
  }

  @override
  Future<DownloadReceipt> finish(String basename, String extension) async =>
      DownloadReceipt('$basename.$extension', '/selected/$basename.$extension');
}

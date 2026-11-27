import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/downloads/download_controller.dart';
import 'package:motif/downloads/download_destination.dart';
import 'package:motif/downloads/download_directory_store.dart';
import 'package:motif/features/downloads/download_page.dart';
import 'package:motif/online/domain/download_source.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/qq/qq_track.dart';

import '../online/playback_fakes.dart';
import '../support/ordered_script_stub.dart';

import 'package:motif/online/lx/lx_ordered_source.dart';

void main() {
  testWidgets(
    'ordered sheet requires an explicit supported tier; retry uses current checked order in the same task',
    (t) async {
      final sources = MusicSourceRegistry(qq: FakePlaybackSource('qq'));
      final a = OrderedScriptStub('A')..unavailable = true;
      final b = OrderedScriptStub('B');
      for (final source in [a, b]) {
        sources.registerManaged(
          MusicSourceRegistration(name: source.sourceId, resolver: source),
        );
      }
      final destination = _Destination();
      final controller = DownloadController(
        sources: sources,
        destination: destination,
        currentScriptOrder: () => ['B'],
      );
      await controller.chooseDirectory();
      addTearDown(controller.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  showTrackDownloadSheet(
                    ctx,
                    controller: controller,
                    track: playbackTrack(1),
                    preferredSourceId: lxOrderedSourceId,
                    scriptOrder: ['A'],
                    quality: OnlineQuality.lossless,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      final start = find.widgetWithText(FilledButton, '开始下载');
      expect(t.widget<FilledButton>(start).onPressed, isNull);
      expect(find.textContaining('没有支持当前音质'), findsOneWidget);
      final quality = t.widget<DropdownButtonFormField<OnlineQuality>>(
        find.byType(DropdownButtonFormField<OnlineQuality>),
      );
      quality.onChanged!(OnlineQuality.high);
      await t.pumpAndSettle();
      await t.tap(start);
      await t.pumpAndSettle();
      final task = controller.tasks.single;
      expect(task.status, DownloadStatus.failed);
      expect(task.received, 0);
      expect(a.transfers, 1);
      expect(b.transfers, 0);
      await controller.retry(task);
      expect(task.status, DownloadStatus.completed);
      expect(task.quality, OnlineQuality.high);
      expect(task.received, 4);
      expect(controller.tasks, [same(task)]);
      expect(a.transfers, 1);
      expect(b.transfers, 1);
      expect(destination.aborted, 1);
    },
  );

  testWidgets(
    'opening the sheet restores the remembered folder; a second song needs no picker',
    (tester) async {
      final source = _Source();
      final dest = _Destination();
      final store = _Saved();
      final controller = DownloadController(
        sources: MusicSourceRegistry(
          qq: FakePlaybackSource('qq'),
          thirdPartySources: [
            MusicSourceRegistration(name: 'Source', resolver: source),
          ],
        ),
        destination: dest,
        directoryStore: store,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showTrackDownloadSheet(
                  context,
                  controller: controller,
                  track: playbackTrack(1),
                  preferredSourceId: 'script',
                  quality: OnlineQuality.standard,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      expect(store.loads, 0);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Selected folder'), findsOneWidget);
        await tester.tap(find.text('开始下载'));
        await tester.pumpAndSettle();
      }
      expect(source.transfers, 2);
      expect(dest.picks, 0);
      expect(store.loads, 1);
    },
  );
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
    DiagnosticTrace? trace,
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
  int picks = 0;
  @override
  Future<DownloadDirectory> restoreDirectory(Uri uri) async =>
      DownloadDirectory(uri, 'Selected folder');
  @override
  Future<DownloadDirectory?> chooseDirectory() async {
    picks++;
    return DownloadDirectory(Uri.parse('file:///selected'), 'Selected folder');
  }

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

class _Saved implements DownloadDirectoryStore {
  int loads = 0;
  @override
  Future<Uri?> load() async {
    loads++;
    return Uri.parse('file:///selected');
  }

  @override
  Future<void> save(Uri uri) async => throw StateError('no selection expected');
}

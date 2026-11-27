import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/audio/controlled_pcm.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/downloads/download_controller.dart';
import 'package:motif/downloads/download_directory_store.dart';
import 'package:motif/downloads/platform_download_destination.dart';
import 'package:motif/downloads/download_destination.dart';
import 'package:motif/online/domain/download_source.dart';
import 'package:motif/online/domain/music_source_registry.dart';
import 'package:motif/online/domain/online_error.dart';
import 'package:motif/online/domain/playback_source.dart';
import 'package:motif/online/qq/qq_track.dart';

final track = QqTrack(
  mid: 'test',
  title: '../Song: title?',
  artists: ['Singer'],
  album: 'Album',
);

void main() {
  late _Source source;
  late _Destination destination;
  late DownloadController controller;
  late DiagnosticRecorder diagnostics;
  setUp(() {
    source = _Source();
    destination = _Destination();
    diagnostics = DiagnosticRecorder();
    controller = DownloadController(
      diagnostics: diagnostics,
      sources: MusicSourceRegistry(
        qq: _Qq(),
        thirdPartySources: [
          MusicSourceRegistration(name: 'Test source', resolver: source),
        ],
      ),
      destination: destination,
    );
  });
  tearDown(() async {
    await controller.close();
    controller.dispose();
    diagnostics.dispose();
  });

  Future<void> restart(
    DownloadDirectoryStore store, [
    DownloadDestination? adapter,
  ]) async {
    final registry = controller.sources;
    await controller.close();
    controller.dispose();
    controller = DownloadController(
      sources: registry,
      destination: adapter ?? destination,
      diagnostics: diagnostics,
      directoryStore: store,
    );
  }

  test('Windows remembers a picker URI across sessions and saves both files without prompting or overwriting', () async {
    final root = await Directory.systemTemp.createTemp('motif-remember-');
    addTearDown(() => root.delete(recursive: true));
    final dir = await Directory.fromUri(root.uri.resolve('下载%20%23100%25'))
        .create();
    final store = FileDownloadDirectoryStore(
      () async => File.fromUri(root.uri.resolve('private/dir.json')),
    );
    var picks = 0;
    final platform = PlatformDownloadDestination(
      windowsPicker: () async {
        picks++;
        return Uri.directory(dir.path, windows: true);
      },
    );
    await restart(store, platform);
    await controller.chooseDirectory();
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'explicit selection cleans up its write probe',
    );
    await controller.start(track, 'test', OnlineQuality.standard);
    final first = controller.tasks.single.receipt!;
    await restart(store, platform);
    expect(controller.tasks, isEmpty);
    await controller.start(track, 'test', OnlineQuality.standard);
    final second = controller.tasks.single.receipt!;
    expect(picks, 1);
    expect(first.location, isNot(second.location));
    for (final receipt in [first, second]) {
      expect(await File(receipt.location).readAsBytes(), List.filled(8, 7));
    }
    expect(dir.listSync(), hasLength(2));
    await dir.delete(recursive: true);
    await restart(store, platform);
    await controller.directoryReady;
    expect(controller.directory, isNull);
    expect(controller.error, contains('重新选择'));
    await controller.start(track, 'test', OnlineQuality.standard);
    expect(source.calls, 2);
    expect(picks, 1);
  }, skip: !Platform.isWindows);

  test('restoration is lazy, shared and cannot replace a later choice; cancelling a picker keeps it', () async {
    final store = _Store()..readGate = Completer<Uri?>();
    await restart(store);
    expect(store.loads, 0);
    final ready = controller.directoryReady;
    expect(store.loads, 1);
    final change = controller.chooseDirectory();
    expect(destination.picks, 0);
    expect(controller.choosing, isTrue);
    store.readGate!.complete(Uri.parse('file:///previous'));
    await ready;
    await change;
    expect(store.saved, [destination.selected.uri]);
    expect(controller.directory?.uri, destination.selected.uri);
    destination.cancelPick = true;
    await controller.chooseDirectory();
    expect(store.saved, hasLength(1));
    expect(controller.directory?.uri, destination.selected.uri);
  });
  test('remembering failure does not discard the working selection or serialize tasks', () async {
    await restart(_Store()..failSave = true);
    await controller.chooseDirectory();
    expect(controller.error, contains('未能记住'));
    expect(controller.directory, same(destination.selected));
    await controller.start(track, 'test', OnlineQuality.standard);
    expect(controller.tasks.single.status, DownloadStatus.completed);
  });
  test('revoked saved grant cannot start a download and retry requires a valid selection', () async {
    final store = _Store()
      ..uri = Uri.parse('content://documents/tree/remembered');
    destination.restoreFailure = PlatformException(
      code: 'download_permission',
      message: 'sensitive locator',
    );
    await restart(store);
    await controller.directoryReady;
    expect(controller.directory, isNull);
    expect(controller.error, contains('重新选择'));
    expect(destination.picks, 0);
    await controller.start(track, 'test', OnlineQuality.standard);
    expect(source.calls, 0);
    await controller.chooseDirectory();
    destination.createFailure = PlatformException(code: 'download_permission');
    await controller.start(track, 'test', OnlineQuality.standard);
    final failed = controller.tasks.single;
    expect(failed.error, contains('权限'));
    expect(controller.directory, isNull);
    await controller.retry(failed);
    expect(source.calls, 0);
    destination.createFailure = null;
    await controller.chooseDirectory();
    await controller.retry(failed);
    expect(controller.tasks, [same(failed)]);
    expect(failed.status, DownloadStatus.completed);
  });
  test('disk full is a write failure, not a permission or source error; keep directory for retry', () async {
    await controller.chooseDirectory();
    diagnostics.setEnabled(true);
    destination.writeFailure = PlatformException(
      code: 'download_space',
      message: 'private disk path',
    );
    await controller.start(track, 'test', OnlineQuality.standard);
    final task = controller.tasks.single;
    expect(task.error, contains('写入下载数据'));
    expect(task.error, contains('空间不足'));
    expect(task.received, 0);
    expect(destination.writers.single.aborted, isTrue);
    expect(controller.directory, isNotNull);
    final text = utf8.decode(diagnostics.export({}).bytes);
    final end = (jsonDecode(text)['events'] as List).singleWhere(
      (r) => r['event'] == 'downloadFinished',
    );
    expect(end['stage'], 'write');
    expect(end['reason'], 'noSpace');
    expect(text, isNot(contains('private disk path')));
  });
  test(
    'source-side filesystem I/O is not mislabeled as a destination failure',
    () async {
      await controller.chooseDirectory();
      source.otherFailure = const FileSystemException('private script path');
      await controller.start(track, 'test', OnlineQuality.standard);
      expect(controller.tasks.single.error, contains('音源'));
      expect(controller.directory, isNotNull);
    },
  );
  test('no directory means no file and no source request', () async {
    await controller.start(track, 'test', OnlineQuality.standard);
    expect(source.calls, 0);
    expect(destination.writers, isEmpty);
    expect(controller.error, isNotNull);
  });

  test(
    'commits only after transfer, reports progress and sanitizes names',
    () async {
      await controller.chooseDirectory();
      await controller.start(track, 'test', OnlineQuality.high);
      final task = controller.tasks.single;
      expect(task.status, DownloadStatus.completed);
      expect(task.received, 8);
      expect(task.total, 8);
      expect(task.quality, OnlineQuality.high);
      expect(destination.writers.single.name, 'Singer - .._Song_ title_');
      expect(destination.writers.single.bytes, List.filled(8, 7));
      expect(destination.writers.single.aborted, isFalse);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'cancellation and duplicate start do not leave an extra transfer',
    () async {
      await controller.chooseDirectory();
      source.gate = Completer<void>();
      final running = controller.start(track, 'test', OnlineQuality.standard);
      await source.started.future;
      await controller.start(track, 'test', OnlineQuality.high);
      expect(source.calls, 1);
      controller.cancel();
      await running;
      expect(controller.tasks.single.status, DownloadStatus.cancelled);
      expect(destination.writers.single.aborted, isTrue);
      expect(destination.writers.single.name, isNull);
    },
  );

  test(
    'retry reuses the failed task, clears progress and uses a fresh file',
    () async {
      diagnostics.setEnabled(true);
      await controller.chooseDirectory();
      source.fail = true;
      await controller.start(track, 'test', OnlineQuality.standard);
      final failed = controller.tasks.single;
      expect(failed.status, DownloadStatus.failed);
      expect(failed.received, 3);
      expect(failed.total, 8);
      expect(failed.error, isNotNull);
      expect(source.calls, 1);
      expect(destination.writers.single.aborted, isTrue);

      destination.selected = DownloadDirectory(
        Uri.parse('file:///replacement'),
        'Replacement',
      );
      await controller.chooseDirectory();
      source.fail = false;
      source.gate = Completer<void>();
      final retrying = controller.retry(failed);
      expect(controller.tasks, [same(failed)]);
      expect(failed.status, DownloadStatus.resolving);
      expect(failed.received, 0);
      expect(failed.total, isNull);
      expect(failed.error, isNull);
      expect(failed.receipt, isNull);
      await controller.retry(failed); // A second tap cannot start an attempt.
      source.gate!.complete();
      await retrying;
      expect(source.calls, 2);
      expect(controller.tasks, [same(failed)]);
      expect(failed.status, DownloadStatus.completed);
      expect(failed.directory, same(destination.selected));
      expect(destination.createdIn.last, same(destination.selected));
      expect(destination.writers.last.bytes.length, 8);
      await controller.retry(failed);
      expect(source.calls, 2, reason: 'a completed task cannot be retried');
      final text = utf8.decode(diagnostics.export({}).bytes);
      final events = (jsonDecode(text) as Map)['events'] as List;
      final attempts = events.where(
        (entry) => entry['event'] == 'downloadRequested',
      );
      expect(attempts.map((entry) => entry['task']), [1, 1]);
      expect(attempts.map((entry) => entry['attempt']), [1, 2]);
      expect(attempts.map((entry) => entry['operationId']), [1, 2]);
      expect(
        events
            .where((entry) => entry['event'] == 'downloadFinished')
            .map((entry) => entry['state']),
        ['failed', 'completed'],
      );
      expect(text, isNot(contains('file:///')));
      expect(text, isNot(contains(track.title)));
    },
  );

  test('cancel during destination creation waits for cleanup before allowing another transfer', () async {
    await controller.chooseDirectory();
    destination.creation = Completer<void>();
    final running = controller.start(track, 'test', OnlineQuality.standard);
    await destination.creating.future;
    controller.cancel();
    expect(controller.busy, isTrue);
    destination.creation!.complete();
    await running;
    expect(destination.writers.single.aborted, isTrue);
    expect(source.calls, 0);
    expect(controller.tasks.single.status, DownloadStatus.cancelled);
  });

  test('an Android directory failure uses a safe save error without resolving the source', () async {
    await controller.chooseDirectory();
    destination.createFailure = PlatformException(
      code: 'download_io',
      message: 'private content URI',
    );
    await controller.start(track, 'test', OnlineQuality.standard);
    expect(controller.tasks.single.status, DownloadStatus.failed);
    expect(controller.tasks.single.error, contains('准备下载目录失败'));
    expect(controller.tasks.single.error, isNot(contains('权限')));
    expect(
      controller.tasks.single.error,
      isNot(contains('private content URI')),
    );
    expect(source.calls, 0);
  });

  test('commit failure removes the incomplete output', () async {
    await controller.chooseDirectory();
    destination.failCommit = true;
    await controller.start(track, 'test', OnlineQuality.standard);
    expect(controller.tasks.single.status, DownloadStatus.failed);
    expect(controller.tasks.single.error, contains('保存最终文件'));
    expect(controller.tasks.single.receipt, isNull);
    expect(destination.writers.single.aborted, isTrue);
  });

  test('source revocation prevents a completed download', () async {
    await controller.chooseDirectory();
    source.gate = Completer<void>();
    final running = controller.start(track, 'test', OnlineQuality.standard);
    await source.started.future;
    controller.sources.close();
    source.gate!.complete();
    await running;
    expect(controller.tasks.single.status, DownloadStatus.failed);
    expect(destination.writers.single.aborted, isTrue);
  });

  test('close cancels active work and waits for destination cleanup', () async {
    await controller.chooseDirectory();
    source.gate = Completer<void>();
    unawaited(controller.start(track, 'test', OnlineQuality.standard));
    await source.started.future;
    await controller.close();
    expect(destination.writers.single.aborted, isTrue);
    expect(controller.busy, isFalse);
  });

  test('portable filenames retain Unicode, remove paths and protect reserved names', () {
    expect(downloadBasename('CON', []), '_CON');
    expect(downloadBasename('..', []), '歌曲');
    expect(downloadBasename('歌名', ['歌手']), '歌手 - 歌名');
    expect(downloadBasename('a/b\\c', []), 'a_b_c');
  });
}

class _Qq implements PlaybackUrlResolver {
  @override
  String get sourceId => 'qq';
  @override
  void close() {}
  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) =>
      throw UnimplementedError();
}

class _Source implements PlaybackUrlResolver, TrackDownloadSource {
  int calls = 0;
  bool fail = false;
  Object? otherFailure;
  final started = Completer<void>();
  Completer<void>? gate;
  @override
  String get sourceId => 'test';
  @override
  Set<OnlineQuality> get downloadQualities => OnlineQuality.values.toSet();
  @override
  Future<String> transfer(
    QqTrack track,
    OnlineQuality quality, {
    required PcmCancellation cancellation,
    required DownloadWrite write,
    required void Function(int) onTotal,
    DiagnosticTrace? trace,
  }) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (gate != null) await cancellation.until(gate!.future);
    cancellation.check();
    if (otherFailure case final failure?) throw failure;
    onTotal(8);
    if (fail) {
      await write(Uint8List.fromList([7, 7, 7]));
      throw const OnlineException(OnlineErrorKind.transport);
    }
    await write(Uint8List.fromList(List.filled(8, 7)));
    return 'mp3';
  }

  @override
  Future<OnlineStream> resolve(QqTrack track, OnlineQuality quality) =>
      throw UnimplementedError();
  @override
  void close() {}
}

class _Destination implements DownloadDestination {
  final writers = <_Writer>[];
  final createdIn = <DownloadDirectory>[];
  DownloadDirectory selected = DownloadDirectory(
    Uri.parse('file:///chosen'),
    'Chosen',
  );
  final creating = Completer<void>();
  Completer<void>? creation;
  Object? createFailure, restoreFailure, writeFailure;
  bool cancelPick = false;
  int picks = 0;
  bool failCommit = false;
  @override
  Future<DownloadDirectory?> chooseDirectory() async {
    picks++;
    return cancelPick ? null : selected;
  }

  @override
  Future<DownloadDirectory> restoreDirectory(Uri uri) async {
    if (restoreFailure case final failure?) throw failure;
    return DownloadDirectory(uri, 'Restored');
  }

  @override
  Future<DownloadWriter> create(DownloadDirectory directory) async {
    if (!creating.isCompleted) creating.complete();
    if (createFailure case final failure?) throw failure;
    if (creation != null) await creation!.future;
    final writer = _Writer(failCommit, writeFailure);
    createdIn.add(directory);
    writers.add(writer);
    return writer;
  }
}

class _Writer implements DownloadWriter {
  _Writer(this.failCommit, this.writeFailure);
  final Object? writeFailure;
  final bool failCommit;
  final bytes = <int>[];
  bool aborted = false;
  String? name;
  @override
  Future<void> write(Uint8List chunk) async {
    if (writeFailure case final failure?) throw failure;
    bytes.addAll(chunk);
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }

  @override
  Future<DownloadReceipt> finish(String basename, String extension) async {
    if (failCommit) throw StateError('save failed');
    name = basename;
    return DownloadReceipt(
      '$basename.$extension',
      '/chosen/$basename.$extension',
    );
  }
}

class _Store implements DownloadDirectoryStore {
  Uri? uri;
  int loads = 0;
  final saved = <Uri>[];
  bool failSave = false;
  Completer<Uri?>? readGate;
  @override
  Future<Uri?> load() async {
    loads++;
    return readGate == null ? uri : await readGate!.future;
  }

  @override
  Future<void> save(Uri value) async {
    if (failSave) throw StateError('fixture');
    uri = value;
    saved.add(value);
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio/controlled_pcm.dart';
import '../online/domain/music_source_registry.dart';
import '../online/domain/online_error.dart';
import '../online/domain/playback_source.dart';
import '../online/qq/qq_track.dart';
import 'download_destination.dart';

enum DownloadStatus {
  resolving,
  downloading,
  saving,
  completed,
  cancelled,
  failed,
}

final class DownloadTask {
  DownloadTask(this.track, this.sourceId, this.quality, this.directory);
  final QqTrack track;
  final String sourceId;
  final OnlineQuality quality;
  final DownloadDirectory directory;
  DownloadStatus status = DownloadStatus.resolving;
  int received = 0;
  int? total;
  DownloadReceipt? receipt;
  String? error;
}

/// One explicit transfer at a time; retry always re-resolves an expiring URL.
/// Only local task metadata is retained, never media URLs or script credentials.
final class DownloadController extends ChangeNotifier {
  DownloadController({required this.sources, required this.destination});
  final MusicSourceRegistry sources;
  final DownloadDestination destination;
  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  DownloadDirectory? directory;
  String? error;
  bool choosing = false;
  bool get busy => _active != null;
  DownloadTask? _active;
  PcmCancellation? _work;
  Future<void>? _running;
  bool _closed = false;

  Future<void> chooseDirectory() async {
    if (choosing || busy || _closed) return;
    choosing = true;
    error = null;
    _notify();
    try {
      final picked = await destination.chooseDirectory();
      if (!_closed && picked != null) directory = picked;
    } catch (_) {
      error = '无法访问保存目录，请重新选择。';
    } finally {
      choosing = false;
      _notify();
    }
  }

  Future<void> start(QqTrack track, String sourceId, OnlineQuality quality) {
    if (_closed || busy || choosing) return Future.value();
    final target = directory;
    if (target == null) {
      error = '请先选择保存目录。';
      _notify();
      return Future.value();
    }
    final task = DownloadTask(track, sourceId, quality, target);
    _tasks.insert(0, task);
    if (_tasks.length > 50) _tasks.removeLast();
    _active = task;
    final work = _work = PcmCancellation();
    error = null;
    _notify();
    return _running = _run(task, work);
  }

  Future<void> retry(DownloadTask task) =>
      start(task.track, task.sourceId, task.quality);

  void cancel() {
    if (_active?.status != DownloadStatus.saving) _work?.cancel();
  }

  Future<void> _run(DownloadTask task, PcmCancellation work) async {
    DownloadWriter? writer;
    var committed = false;
    var notifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final output = await destination.create(task.directory);
      writer = output;
      work.check();
      final extension = await sources.download(
        task.sourceId,
        task.track,
        task.quality,
        cancellation: work,
        write: (bytes) async {
          work.check();
          await output.write(bytes);
          work.check();
          task.received += bytes.length;
          task.status = DownloadStatus.downloading;
          final now = DateTime.now();
          if (now.difference(notifiedAt).inMilliseconds >= 100) {
            notifiedAt = now;
            _notify();
          }
        },
        onTotal: (total) {
          task.total = total;
          _notify();
        },
      );
      work.check();
      task.status = DownloadStatus.saving;
      _notify();
      task.receipt = await output.finish(
        downloadBasename(task.track.title, task.track.artists),
        extension,
      );
      committed = true;
      task.status = DownloadStatus.completed;
    } catch (failure) {
      task.status = work.cancelled
          ? DownloadStatus.cancelled
          : DownloadStatus.failed;
      task.error = work.cancelled
          ? null
          : failure is OnlineException
          ? failure.toString()
          : failure is FileSystemException
          ? '无法写入文件，请检查保存目录和可用空间。'
          : '下载未完成，请检查音源和保存目录后重试。';
    } finally {
      if (!committed && writer != null) {
        try {
          await writer.abort();
        } catch (_) {
          task.error = '临时文件未能清理，请检查保存目录后重试。';
        }
      }
      work.cancel();
      _active = null;
      _work = null;
      _notify();
    }
  }

  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _work?.cancel();
    }
    await _running;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

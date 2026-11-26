import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../audio/controlled_pcm.dart';
import '../diagnostics/diagnostic_failure.dart';
import '../diagnostics/diagnostic_recorder.dart';
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
  DownloadTask._(
    this._id,
    this.track,
    this.sourceId,
    this.quality,
    this._directory,
  );
  final int _id;
  int _attempt = 0;
  final QqTrack track;
  final String sourceId;
  final OnlineQuality quality;
  DownloadDirectory _directory;
  DownloadDirectory get directory => _directory;
  DownloadStatus _status = DownloadStatus.resolving;
  DownloadStatus get status => _status;
  int _received = 0;
  int get received => _received;
  int? _total;
  int? get total => _total;
  DownloadReceipt? _receipt;
  DownloadReceipt? get receipt => _receipt;
  String? _error;
  String? get error => _error;

  bool get retryable =>
      _status == DownloadStatus.failed || _status == DownloadStatus.cancelled;
}

/// One explicit transfer at a time; retry always re-resolves an expiring URL.
/// Only local task metadata is retained, never media URLs or script credentials.
final class DownloadController extends ChangeNotifier {
  DownloadController({
    required this.sources,
    required this.destination,
    this.diagnostics,
  });
  final DiagnosticRecorder? diagnostics;
  final MusicSourceRegistry sources;
  int _nextTask = 0;
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
    final task = DownloadTask._(++_nextTask, track, sourceId, quality, target);
    _tasks.insert(0, task);
    if (_tasks.length > 50) _tasks.removeLast();
    return _begin(task);
  }

  Future<void> retry(DownloadTask task) {
    if (_closed ||
        busy ||
        choosing ||
        !task.retryable ||
        !_tasks.contains(task)) {
      return Future.value();
    }
    // A newly selected directory can recover the same task from a stale grant.
    task._directory = directory ?? task.directory;
    task._status = DownloadStatus.resolving;
    task._received = 0;
    task._total = null;
    task._receipt = null;
    task._error = null;
    return _begin(task);
  }

  Future<void> _begin(DownloadTask task) {
    _active = task;
    final work = _work = PcmCancellation();
    error = null;
    final trace = diagnostics?.begin(DiagnosticOperation.download);
    task._attempt++;
    trace?.record(DiagnosticEvent.downloadRequested, {
      DiagnosticField.task: task._id,
      DiagnosticField.attempt: task._attempt,
      DiagnosticField.quality: task.quality,
    });
    // Publish the future before notifying; a listener can cancel or close now.
    final running = _running = Future.microtask(() => _run(task, work, trace));
    _notify();
    return running;
  }

  void cancel() {
    if (_active?.status != DownloadStatus.saving) _work?.cancel();
  }

  DiagnosticFacts diagnosticSnapshot() => {
    DiagnosticField.taskCount: _tasks.length,
    DiagnosticField.directorySelected: directory != null,
    DiagnosticField.active: busy,
    if (_active case final task?) ...{
      DiagnosticField.task: task._id,
      DiagnosticField.attempt: task._attempt,
      DiagnosticField.state: task.status,
      DiagnosticField.bytes: task.received,
      DiagnosticField.totalBytes: task.total,
    },
  };

  Future<void> _run(
    DownloadTask task,
    PcmCancellation work,
    DiagnosticTrace? trace,
  ) async {
    DownloadWriter? writer;
    var stage = DiagnosticStage.directory;
    var committed = false;
    var notifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      work.check();
      final output = await destination.create(task.directory);
      writer = output;
      work.check();
      stage = DiagnosticStage.transfer;
      final extension = await sources.download(
        task.sourceId,
        task.track,
        task.quality,
        cancellation: work,
        trace: trace,
        write: (bytes) async {
          work.check();
          await output.write(bytes);
          work.check();
          task._received += bytes.length;
          task._status = DownloadStatus.downloading;
          final now = DateTime.now();
          if (now.difference(notifiedAt).inMilliseconds >= 100) {
            notifiedAt = now;
            _notify();
          }
        },
        onTotal: (total) {
          trace?.record(DiagnosticEvent.downloadBody, {
            DiagnosticField.totalBytes: total,
          });
          task._total = total;
          _notify();
        },
      );
      work.check();
      stage = DiagnosticStage.save;
      trace?.record(DiagnosticEvent.downloadSaving, {
        DiagnosticField.bytes: task.received,
      });
      task._status = DownloadStatus.saving;
      _notify();
      work.check();
      task._receipt = await output.finish(
        downloadBasename(task.track.title, task.track.artists),
        extension,
      );
      committed = true;
      task._status = DownloadStatus.completed;
      trace?.record(DiagnosticEvent.downloadFinished, {
        DiagnosticField.state: task.status,
        DiagnosticField.bytes: task.received,
      });
    } catch (failure) {
      task._status = work.cancelled
          ? DownloadStatus.cancelled
          : DownloadStatus.failed;
      task._error = work.cancelled
          ? null
          : failure is OnlineException
          ? failure.toString()
          : _isDestinationFailure(failure)
          ? '无法写入文件，请检查保存目录权限和可用空间。'
          : '下载未完成，请检查音源和保存目录后重试。';
      if (trace?.active == true) {
        trace!.record(DiagnosticEvent.downloadFinished, {
          DiagnosticField.stage: stage,
          DiagnosticField.state: task.status,
          DiagnosticField.bytes: task.received,
          if (!work.cancelled) ...diagnosticFailure(failure),
        });
      }
    } finally {
      if (!committed && writer != null) {
        try {
          await writer.abort();
        } catch (_) {
          trace?.record(DiagnosticEvent.downloadCleanupFailure);
          task._error = '临时文件未能清理，请检查保存目录后重试。';
        }
      }
      work.cancel();
      _active = null;
      _work = null;
      _notify();
    }
  }

  bool _isDestinationFailure(Object failure) =>
      failure is FileSystemException ||
      failure is PlatformException &&
          const {'download_io', 'download_directory'}.contains(failure.code);

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

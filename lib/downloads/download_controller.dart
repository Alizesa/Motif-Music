import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/controlled_pcm.dart';
import '../diagnostics/diagnostic_failure.dart';
import '../diagnostics/diagnostic_recorder.dart';
import '../online/domain/music_source_registry.dart';
import '../online/domain/online_error.dart';
import '../online/domain/playback_source.dart';
import '../online/lx/lx_ordered_source.dart';
import '../online/qq/qq_track.dart';
import 'download_destination.dart';
import 'download_directory_store.dart';
import 'download_storage_error.dart';

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
    this._scriptOrder,
  );
  final int _id;
  int _attempt = 0;
  final QqTrack track;
  final String sourceId;
  List<String> _scriptOrder;
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
    this.directoryStore,
    this.currentScriptOrder,
  });
  final DownloadDirectoryStore? directoryStore;
  final List<String> Function()? currentScriptOrder;
  // A saved directory can be on a removable drive, network share or cloud
  // provider. Don't touch it just because the user opened the music player.
  late final Future<void> directoryReady = _restoreDirectory();
  Future<void>? _savingSelection;
  final DiagnosticRecorder? diagnostics;
  final MusicSourceRegistry sources;
  int _nextTask = 0;
  final DownloadDestination destination;
  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  DownloadDirectory? _directory;
  DownloadDirectory? get directory => _directory;
  String? error;
  bool _picking = false;
  bool _restoring = false;
  bool get restoring => _restoring;
  bool get choosing => _picking || _restoring;
  bool get busy => _active != null;
  DownloadTask? _active;
  PcmCancellation? _work;
  Future<void>? _running;
  bool _closed = false;

  Future<void> _restoreDirectory() async {
    final store = directoryStore;
    if (store == null) return;
    _restoring = true;
    try {
      final uri = await store.load();
      if (uri == null || _closed) return;
      final restored = await destination
          .restoreDirectory(uri)
          .timeout(const Duration(seconds: 5));
      if (!_closed) _directory = restored;
    } catch (failure) {
      if (!_closed) {
        error = switch (DownloadStorageException.from(failure).problem) {
          DownloadStorageProblem.permission => '上次保存目录的写入授权已失效或目录不可写，请重新选择。',
          DownloadStorageProblem.unavailable => '上次保存目录已不存在或存储设备未连接，请重新选择。',
          _ => '无法恢复上次的保存目录，请重新选择。',
        };
      }
    } finally {
      _restoring = false;
      _notify();
    }
  }

  Future<void> chooseDirectory() async {
    if (_picking || busy || _closed) return;
    _picking = true;
    _notify();
    try {
      await directoryReady;
      if (_closed) return;
      final picked = await destination.chooseDirectory();
      // Cancelling retains the previous choice.
      if (_closed || picked == null) return;
      _directory = picked;
      error = null;
      try {
        await (_savingSelection = directoryStore?.save(picked.uri));
      } catch (_) {
        error = '已选择本次保存目录，但未能记住此更改。';
      } finally {
        _savingSelection = null;
      }
    } catch (failure) {
      error = DownloadStorageException.from(failure).message('选择保存目录');
    } finally {
      _picking = false;
      _notify();
    }
  }

  Future<void> start(
    QqTrack track,
    String sourceId,
    OnlineQuality quality, {
    List<String> scriptOrder = const [],
  }) async {
    if (_closed || busy || _picking) return;
    await directoryReady;
    if (_closed || busy || choosing) return;
    final target = directory;
    if (target == null) {
      error = '请先选择保存目录。';
      _notify();
      return;
    }
    final task = DownloadTask._(
      ++_nextTask,
      track,
      sourceId,
      quality,
      target,
      List.unmodifiable(scriptOrder),
    );
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
    final target = directory;
    if (target == null) {
      error = '请先重新选择保存目录。';
      _notify();
      return Future.value();
    }
    task._directory = target;
    if (task.sourceId == lxOrderedSourceId && currentScriptOrder != null) {
      task._scriptOrder = List.unmodifiable(currentScriptOrder!());
    }
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
        scriptOrder: task._scriptOrder,
        cancellation: work,
        trace: trace,
        write: (bytes) async {
          work.check();
          stage = DiagnosticStage.write;
          await output.write(bytes);
          stage = DiagnosticStage.transfer;
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
      final storageAction = switch (stage) {
        DiagnosticStage.directory => '准备下载目录',
        DiagnosticStage.write => '写入下载数据',
        DiagnosticStage.save => '保存最终文件',
        _ => null,
      };
      final storage = storageAction == null
          ? null
          : DownloadStorageException.from(failure);
      task._error = work.cancelled
          ? null
          : storage != null
          ? storage.message(storageAction!)
          : failure is OnlineException
          ? failure.toString()
          : '下载未完成，请检查音源后重试。';
      if (!work.cancelled &&
          storage != null &&
          (storage.problem == DownloadStorageProblem.permission ||
              storage.problem == DownloadStorageProblem.unavailable) &&
          _directory?.uri == task.directory.uri) {
        // Do not silently fall back to another folder or reuse a revoked grant.
        _directory = null;
        error = '当前保存目录不可用，请重新选择。';
      }
      if (trace?.active == true) {
        trace!.record(DiagnosticEvent.downloadFinished, {
          DiagnosticField.stage: stage,
          DiagnosticField.state: task.status,
          DiagnosticField.bytes: task.received,
          if (!work.cancelled) ...diagnosticFailure(storage ?? failure),
        });
      }
    } finally {
      if (!committed && writer != null) {
        try {
          await writer.abort();
        } catch (_) {
          trace?.record(DiagnosticEvent.downloadCleanupFailure);
          task._error = [
            if (task._error != null) task._error,
            '临时文件未能清理，请检查保存目录。',
          ].join(' ');
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
    // A selection already handed to the store is committed even during exit.
    try {
      await _savingSelection;
    } catch (_) {
      /* surfaced by chooseDirectory */
    }
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

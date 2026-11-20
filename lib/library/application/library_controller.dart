import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/library_database.dart';
import '../data/library_repository.dart';
import '../data/open_library_database.dart';
import '../domain/library_models.dart';
import '../platform/library_file_access.dart';
import '../platform/library_metadata_reader.dart';
import '../platform/taglib_metadata_reader.dart';
import 'library_metadata_service.dart';
import '../platform/library_platform_source.dart';
import '../platform/library_platform_source_factory.dart';
import 'library_scan_service.dart';

/// One application-owned database and a single bounded page, independent of routes.
final class LibraryController extends ChangeNotifier {
  LibraryController({
    required LibraryDatabase database,
    required LibraryPlatformSource source,
    Future<void> Function(FileLocation)? verifyFile,
    LibraryMetadataReader? metadataReader,
  }) : _database = database,
       _repository = LibraryRepository(database),
       _source = source,
       _verifyFile = verifyFile ?? verifyLibraryFileAccess {
    _scanner = LibraryScanService(_repository, source);
    _metadataService = metadataReader == null
        ? null
        : LibraryMetadataService(_repository, metadataReader);
  }

  factory LibraryController.open() => LibraryController(
    database: openLibraryDatabase(),
    source: createLibraryPlatformSource(),
    metadataReader: const TagLibMetadataReader(),
  );

  static const pageSize = 100;
  final LibraryDatabase _database;
  final LibraryRepository _repository;
  final LibraryPlatformSource _source;
  final Future<void> Function(FileLocation) _verifyFile;
  late final LibraryScanService _scanner;
  late final LibraryMetadataService? _metadataService;
  Future<void>? _metadataOperation;
  LibraryScanCancellation? _metadataCancellation;
  bool _metadataRequested = false;
  bool _retryFailedRequested = false;
  bool _metadataPageDirty = false;
  MetadataProgress _metadataProgress = const MetadataProgress();
  String? _metadataMessage;
  final LibraryScanCancellation _lifetime = LibraryScanCancellation();
  final List<int> _pageStarts = [0];
  Future<void>? _initializing;
  Future<bool>? _operation;
  Future<void>? _closing;
  LibraryScanCancellation? _scanCancellation;
  bool _closed = false;
  bool _initializingNow = false;
  bool _working = false;
  bool _initialized = false;
  int _pageIndex = 0;
  List<LibraryDirectory> _directories = const [];
  List<LocalAudioFile> _files = const [];
  bool _hasNextPage = false;
  String? _errorMessage;
  String? _notice;
  int? _activeRootId;
  int _indexedFiles = 0;

  List<LibraryDirectory> get directories => _directories;
  List<LocalAudioFile> get files => _files;
  bool get initialized => _initialized;
  bool get isBusy => _initializingNow || _working || _closed;
  bool get isInitializing => _initializingNow;
  bool get isScanning => _activeRootId != null;
  bool get isCancelling => _scanCancellation?.isCancelled ?? false;
  bool get hasNextPage => _hasNextPage;
  bool get hasPreviousPage => _pageIndex > 0;
  int get pageNumber => _pageIndex + 1;
  String? get errorMessage => _errorMessage;
  String? get notice => _notice;
  int? get activeRootId => _activeRootId;
  int get indexedFiles => _indexedFiles;
  bool get metadataEnabled => _metadataService != null;
  bool get isReadingMetadata => _metadataOperation != null;
  bool get isMetadataCancelling => _metadataCancellation?.isCancelled ?? false;
  MetadataProgress get metadataProgress => _metadataProgress;
  String? get metadataMessage => _metadataMessage;

  Future<void> initialize() {
    if (_closed || _initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<void> _initialize() async {
    _initializingNow = true;
    _errorMessage = null;
    _notify();
    try {
      // Recover before admitting any new scan, once for this application instance.
      await _repository.recoverInterruptedScans();
      if (_closed) return;
      await _reload();
      if (!_closed) _initialized = true;
    } catch (error) {
      _errorMessage = '曲库初始化失败，请重试：$error';
    } finally {
      _initializingNow = false;
      _notify();
      if (_initialized && !_closed) unawaited(startMetadata());
    }
  }

  Future<bool> addDirectory() => _run('添加目录失败', () async {
    final picked = await _whileOpen(_source.pickDirectory());
    if (picked == null || _closed) return;
    if (picked.location.platform != _source.platform) {
      throw StateError('目录所属平台不匹配');
    }
    final root = await _repository.addDirectory(
      location: picked.location,
      displayName: picked.displayName,
    );
    if (_closed) return;
    _directories = List.unmodifiable(await _repository.directories());
    if (!_closed) await _scanRoot(root.id);
  }, changesLibrary: true);

  Future<bool> scanDirectory(int rootId) =>
      _run('扫描失败', () => _scanRoot(rootId), changesLibrary: true);

  Future<void> _scanRoot(int rootId) async {
    if (_closed) return;
    _activeRootId = rootId;
    _indexedFiles = 0;
    final cancellation = _scanCancellation = LibraryScanCancellation();
    _notify();
    final count = await _scanner.scanDirectory(
      rootId,
      cancellation: cancellation,
      onProgress: (count) {
        _indexedFiles = count;
        _notify();
      },
    );
    _notice = '扫描完成，共登记 $count 个音频文件。';
  }

  void cancelScan() {
    _scanCancellation?.cancel();
    _notify();
  }

  Future<bool> removeDirectory(int rootId) => _run('移除目录失败', () async {
    await _scanner.removeDirectory(rootId);
    _notice = '目录已从曲库移除，原始文件保留。';
  }, changesLibrary: true);

  Future<bool> refresh() => _run('读取曲库失败', () async {});

  Future<bool> nextPage() => _run('读取下一页失败', () async {
    if (!_hasNextPage || _files.isEmpty) return;
    final afterId = _files.last.id;
    final rows = await _repository.filesPage(
      afterId: afterId,
      limit: pageSize + 1,
    );
    if (_closed) return;
    _pageStarts.removeRange(_pageIndex + 1, _pageStarts.length);
    _pageStarts.add(afterId);
    _pageIndex++;
    _setPage(rows);
  }, reload: false);

  Future<bool> previousPage() => _run('读取上一页失败', () async {
    if (_pageIndex == 0) return;
    final rows = await _repository.filesPage(
      afterId: _pageStarts[_pageIndex - 1],
      limit: pageSize + 1,
    );
    if (_closed) return;
    _pageIndex--;
    _setPage(rows);
  }, reload: false);

  Future<bool> playFile(
    int fileId,
    Future<void> Function(LocalAudioFile) play,
  ) => _run('播放失败', () async {
    final current = await _repository.fileById(fileId);
    if (_closed) return;
    if (current == null) throw StateError('文件已移除或目录不可访问，请刷新曲库');
    await _whileOpen(_verifyFile(current.location));
    if (_closed) return;
    await _whileOpen(play(current));
  }, reload: false);

  Future<bool> _run(
    String failure,
    Future<void> Function() action, {
    bool reload = true,
    bool changesLibrary = false,
  }) {
    if (isBusy || !_initialized) return Future.value(false);
    if (changesLibrary) {
      _metadataCancellation?.cancel();
      _metadataRequested = metadataEnabled;
    }
    _working = true;
    _errorMessage = null;
    _notice = null;
    _notify();
    if (_closed) return Future.value(false);
    return _operation = _execute(failure, action, reload);
  }

  Future<bool> _execute(
    String failure,
    Future<void> Function() action,
    bool reload,
  ) async {
    var succeeded = false;
    try {
      await action();
      succeeded = !_closed;
    } on LibraryScanCancelledException {
      _notice = '扫描已取消，已登记的曲目和原有记录保留。';
    } catch (error) {
      _errorMessage = '$failure：$error';
    } finally {
      _activeRootId = null;
      _scanCancellation = null;
      if (reload && !_closed) {
        try {
          await _reload();
        } catch (error) {
          _errorMessage =
              '${_errorMessage == null ? '' : '${_errorMessage!}\n'}读取曲库失败：$error';
          succeeded = false;
        }
      }
      _working = false;
      if (_metadataPageDirty && !_closed) {
        try {
          await _refreshMetadataPage();
        } catch (error) {
          _metadataMessage = '读取元数据列表失败，可刷新重试：$error';
        }
      }
      _notify();
      if (_metadataRequested && !_closed) unawaited(startMetadata());
    }
    return succeeded;
  }

  /// A finite background pass, independent of the playback/UI operation lock.
  /// Repeated requests coalesce; they never create parallel native readers.
  Future<void> startMetadata({bool retryFailed = false}) {
    if (_closed || !_initialized || !metadataEnabled) return Future.value();
    _metadataRequested = true;
    _retryFailedRequested |= retryFailed;
    if (_metadataOperation != null) return _metadataOperation!;
    if (_working) return Future.value();
    final done = Completer<void>();
    _metadataOperation = done.future;
    unawaited(
      _drainMetadata().then((_) {
        _metadataOperation = null;
        _metadataCancellation = null;
        _notify();
        done.complete();
        if (_metadataRequested && !_closed && !_working) {
          unawaited(startMetadata());
        }
      }),
    );
    _notify();
    return done.future;
  }

  void cancelMetadata() {
    _metadataRequested = false;
    _retryFailedRequested = false;
    _metadataCancellation?.cancel();
    _metadataMessage = '已请求取消；当前读取结束后停止，迟到结果不回写。';
    _notify();
  }

  Future<void> _drainMetadata() async {
    try {
      while (_metadataRequested && !_closed && !_working) {
        _metadataRequested = false;
        final retry = _retryFailedRequested;
        _retryFailedRequested = false;
        final cancellation = _metadataCancellation = LibraryScanCancellation();
        _metadataProgress = const MetadataProgress();
        _metadataMessage = null;
        final result = await _metadataService!.run(
          cancellation: cancellation,
          includeFailed: retry,
          onProgress: (progress) async {
            _metadataProgress = progress;
            if ((progress.processed + progress.discarded) % 20 == 0) {
              await _refreshMetadataPage();
            }
            _notify();
          },
        );
        if (_closed) return;
        _metadataProgress = result;
        _metadataMessage = cancellation.isCancelled
            ? '元数据解析已取消，待解析曲目可继续处理。'
            : '本轮已处理 ${result.processed} 首，失败 ${result.failed} 首，过期结果 ${result.discarded} 首。';
        await _refreshMetadataPage();
      }
    } catch (error) {
      _metadataMessage = '元数据处理失败，可继续处理或重试：$error';
      _metadataRequested = false;
    }
  }

  Future<void> _refreshMetadataPage() async {
    if (_closed) return;
    _metadataPageDirty = true;
    if (isBusy) return;
    final index = _pageIndex;
    final cursor = _pageStarts[index];
    final rows = await _repository.filesPage(
      afterId: cursor,
      limit: pageSize + 1,
    );
    if (_closed ||
        _working ||
        index != _pageIndex ||
        _pageStarts[index] != cursor) {
      return;
    }
    _setPage(rows);
    _metadataPageDirty = false;
  }

  Future<void> _reload() async {
    final roots = await _repository.directories();
    if (_closed) return;
    final rows = await _repository.filesPage(limit: pageSize + 1);
    if (_closed) return;
    _directories = List.unmodifiable(roots);
    _pageStarts
      ..clear()
      ..add(0);
    _pageIndex = 0;
    _setPage(rows);
  }

  void _setPage(List<LocalAudioFile> rows) {
    _hasNextPage = rows.length > pageSize;
    _files = List.unmodifiable(rows.take(pageSize));
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// External pickers/probes may outlive a route or engine; detach their wait.
  Future<T> _whileOpen<T>(Future<T> operation) async {
    final result = Completer<T>();
    final stop = _lifetime.onCancel(() {
      if (!result.isCompleted) {
        result.completeError(const LibraryScanCancelledException());
      }
    });
    unawaited(
      operation.then<void>(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    try {
      return await result.future;
    } finally {
      stop();
    }
  }

  Future<void> close() {
    if (!_closed) dispose();
    return _closing!;
  }

  Future<void> _finishClose() async {
    // Finish outstanding database transactions before closing the executor.
    try {
      if (_initializing != null) await _initializing;
      if (_operation != null) await _operation;
      if (_metadataOperation != null) await _metadataOperation;
    } finally {
      await _database.close();
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _lifetime.cancel();
    _scanCancellation?.cancel();
    _metadataRequested = false;
    _metadataCancellation?.cancel();
    super.dispose();
    _closing = _finishClose();
  }
}

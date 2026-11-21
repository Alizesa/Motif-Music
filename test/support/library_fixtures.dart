import 'dart:async';
import 'dart:io';

import 'package:motif/audio/audio_engine.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';
import 'package:motif/library/platform/library_metadata_reader.dart';

const testDirectory = PickedLibraryDirectory(
  location: FileLocation(
    platform: LibraryPlatform.windows,
    key: 'test-root',
    locator: 'file:///C:/music',
  ),
  displayName: '测试音乐',
);

ObservedAudioFile testAudio(int number) => ObservedAudioFile(
  location: FileLocation(
    platform: LibraryPlatform.windows,
    key: 'file-$number',
    locator: 'file:///C:/music/track-$number.flac',
  ),
  fileName: 'track-$number.flac',
  sizeBytes: 42,
  modifiedMs: 100,
);

class FakeLibrarySource implements LibraryPlatformSource {
  PickedLibraryDirectory? picked = testDirectory;
  Future<PickedLibraryDirectory?>? pickerFuture;
  List<ObservedAudioFile> files = [];
  LibraryTraversalException? traversalError;
  Future<void> Function(int batch, LibraryScanCancellation cancellation)?
  beforeBatch;
  final List<FileLocation> released = [];
  int scanCalls = 0;

  @override
  LibraryPlatform get platform => LibraryPlatform.windows;

  @override
  Future<PickedLibraryDirectory?> pickDirectory() =>
      pickerFuture ?? Future.value(picked);

  @override
  Future<void> releaseDirectory(FileLocation root) async => released.add(root);

  @override
  Stream<List<ObservedAudioFile>> scanBatches(
    FileLocation root, {
    required LibraryScanCancellation cancellation,
  }) async* {
    scanCalls++;
    for (var start = 0; start < files.length; start += libraryScanBatchLimit) {
      await beforeBatch?.call(start ~/ libraryScanBatchLimit, cancellation);
      cancellation.throwIfCancelled();
      final end = start + libraryScanBatchLimit;
      yield files.sublist(start, end < files.length ? end : files.length);
    }
    if (traversalError case final error?) throw error;
  }
}

class FakeAudioEngine implements AudioEngine, ApplicationQueueAudioEngine {
  final _errors = StreamController<String>.broadcast();
  final _queue = StreamController<AudioQueueSnapshot>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _navigation = StreamController<AudioQueueNavigation>.broadcast();
  bool applicationNavigation = false;
  bool _isPlaying = false;
  List<AudioTrack> opened = [];
  int disposeCount = 0;
  int openCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  Object? openError;
  Future<void>? openWait;

  void reportError(String message) => _errors.add(message);
  void requestNavigation(AudioQueueNavigation command) =>
      _navigation.add(command);
  @override
  Stream<AudioQueueNavigation> get navigationRequests => _navigation.stream;
  @override
  void useApplicationQueueNavigation(bool enabled) =>
      applicationNavigation = enabled;
  void completeTrack() {
    _isPlaying = false;
    _playing.add(false);
    _completed.add(true);
  }

  @override
  Stream<bool> get playWhenReady async* {
    yield _isPlaying;
    yield* _playing.stream;
  }

  @override
  Stream<Duration> get position => Stream<Duration>.value(Duration.zero);
  @override
  Stream<Duration> get duration => Stream<Duration>.value(Duration.zero);
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<AudioQueueSnapshot> get queue => _queue.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Future<void> openQueue(List<AudioTrack> tracks) async {
    openCount++;
    if (openError case final error?) throw error;
    if (openWait case final pending?) await pending;
    opened = List.of(tracks);
    _completed.add(false);
    _isPlaying = true;
    _playing.add(true);
    _queue.add(AudioQueueSnapshot(tracks: opened, currentIndex: 0));
  }

  @override
  Future<void> play() async {
    playCount++;
    _isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<bool> next() async => false;
  @override
  Future<bool> previous() async => false;
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double percent) async {}
  @override
  Future<void> setEqualizer(List<double> gainsDb) async {}
  @override
  Future<void> setPreamp(double gainDb) async {}
  @override
  Future<void> dispose() async {
    if (disposeCount++ > 0) return;
    await _errors.close();
    await _queue.close();
    await _completed.close();
    await _playing.close();
    await _navigation.close();
  }
}

Future<void> deleteTestDirectory(Directory directory) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          attempt >= 4 ||
          ![32, 145].contains(error.osError?.errorCode)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

class FakeMetadataReader implements LibraryMetadataReader {
  FakeMetadataReader(this.callback);
  final Future<TrackMetadata> Function(LocalAudioFile) callback;
  final List<int> calls = [];
  int active = 0;
  int maxActive = 0;
  @override
  Future<TrackMetadata> read(LocalAudioFile file) async {
    calls.add(file.id);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      return await callback(file);
    } finally {
      active--;
    }
  }
}

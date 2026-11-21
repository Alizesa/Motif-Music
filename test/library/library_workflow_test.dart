import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/android_saf_library_source.dart';
import 'package:motif/library/platform/library_metadata_reader.dart';
import 'package:motif/library/platform/taglib_metadata_reader.dart';
import 'package:motif/library/platform/windows_library_source.dart';

import '../support/library_fixtures.dart';
import '../support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('motif/library_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('filesystem scan resumes only pending metadata after cancellation and restart', () async {
    final temp = await Directory.systemTemp.createTemp('motif-workflow-');
    addTearDown(() => deleteTestDirectory(temp));
    final database = File.fromUri(temp.uri.resolve('library.sqlite'));
    final music = await Directory.fromUri(temp.uri.resolve('music/')).create();
    final fixture = wavFixture();
    for (final name in ['one.wav', 'two.WAV']) {
      await File.fromUri(music.uri.resolve(name)).writeAsBytes(fixture);
    }
    LibraryDatabase openDatabase() => LibraryDatabase(NativeDatabase(database));
    LibraryController open(LibraryDatabase db, LibraryMetadataReader reader) =>
        LibraryController(
          database: db,
          source: const WindowsLibrarySource(),
          metadataReader: reader,
        );

    final entered = Completer<void>();
    final lateResult = Completer<TrackMetadata>();
    const ready = TrackMetadata(title: 'Before restart', durationMs: 1000);
    var reads = 0;
    final initialReader = FakeMetadataReader((_) {
      if (++reads == 1) return Future.value(ready);
      entered.complete();
      return lateResult.future;
    });
    final db = openDatabase();
    var library = open(db, initialReader);
    addTearDown(() async {
      if (!lateResult.isCompleted) lateResult.complete(ready);
      await library.close();
    });

    // Use the real filesystem scanner on both Windows and Linux. The Windows
    // picker itself translates Windows paths and is not part of this check.
    final root = await LibraryRepository(db).addDirectory(
      location: FileLocation(
        platform: LibraryPlatform.windows,
        key: 'workflow-root',
        locator: music.uri.toString(),
      ),
      displayName: 'Music',
    );
    final rootId = root.id;
    await library.initialize();
    await _metadataIdle(library);
    expect(
      await library.scanDirectory(rootId),
      isTrue,
      reason: library.errorMessage,
    );
    await entered.future;
    final ids = library.files.map((file) => file.id).toList();
    expect(ids, hasLength(2));
    expect(initialReader.calls, ids);
    final pendingId = ids.last;

    LocalAudioFile? played;
    expect(
      await library.playFile(pendingId, (file) async => played = file),
      isTrue,
      reason: library.errorMessage,
    );
    expect(played?.metadata.state, MetadataState.pending);
    expect(played?.id, pendingId);
    library.cancelMetadata();
    lateResult.complete(const TrackMetadata(title: 'Discard this result'));
    await _metadataIdle(library);
    expect(library.files.first.metadata.title, ready.title);
    expect(library.files.last.metadata.state, MetadataState.pending);
    expect(library.files.last.metadata.title, isEmpty);
    await library.close();

    final replacement = wavFixture(seconds: 2);
    final resumedReader = FakeMetadataReader((file) async {
      if (file.sizeBytes == replacement.length) {
        return const TrackMetadata(title: 'After rescan', durationMs: 2000);
      }
      return const TrackMetadata(title: 'After restart', durationMs: 1000);
    });
    library = open(openDatabase(), resumedReader);
    await library.initialize();
    await _metadataIdle(library);
    expect(library.directories.single.id, rootId);
    expect(library.files.map((file) => file.id), ids);
    expect(resumedReader.calls, [pendingId]);
    expect(library.files.first.metadata.title, ready.title);
    final resumed = library.files.last;
    expect(resumed.metadata.title, 'After restart');
    expect(resumed.metadata.durationMs, 1000);

    await File.fromUri(Uri.parse(resumed.location.locator))
        .writeAsBytes(replacement);
    expect(
      await library.scanDirectory(rootId),
      isTrue,
      reason: library.errorMessage,
    );
    await _metadataIdle(library);
    expect(library.files.map((file) => file.id), ids);
    expect(resumedReader.calls, [pendingId, pendingId]);
    final changed = library.files.last;
    expect(changed.revision, greaterThan(resumed.revision));
    expect(changed.sizeBytes, replacement.length);
    expect(changed.metadata.title, 'After rescan');
    expect(changed.metadata.durationMs, 2000);
  });

  test('mock SAF revocation blocks playback and reselecting restores the same track', () async {
    const tree = 'content://provider/tree/music';
    const document = 'content://provider/tree/music/document/music%2Fone.wav';
    const stat = {'sizeBytes': 16044, 'modifiedMs': 100};
    var grant = false;
    var batchSent = false;
    final checks = <String>[];
    final closed = <int>[];
    final originalPicker = FilePickerPlatform.instance;
    addTearDown(() {
      FilePickerPlatform.instance = originalPicker;
      messenger.setMockMethodCallHandler(channel, null);
    });
    FilePickerPlatform.instance = _DirectoryPicker(() {
      grant = true;
      return Uri.parse(tree);
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      switch (call.method) {
        case 'persistedTrees':
          return [if (grant) tree];
        case 'describeTree':
          expect(args?['treeUri'], tree);
          expect(grant, isTrue);
          return {'key': 'provider|music', 'displayName': 'Music'};
        case 'startScan':
          expect(args?['treeUri'], tree);
          if (!grant) throw PlatformException(code: 'permission_revoked');
          batchSent = false;
          return null;
        case 'nextBatch':
          if (batchSent) return {'type': 'complete'};
          batchSent = true;
          return {
            'type': 'batch',
            'files': [
              {
                'key': 'provider|music/one.wav',
                'locator': document,
                'fileName': 'one.wav',
                ...stat,
              },
            ],
          };
        case 'openMetadataFile':
        case 'metadataFileState':
          expect(grant, isTrue);
          expect(args?['uri'], document);
          return {...stat, if (call.method == 'openMetadataFile') 'fd': 77};
        case 'checkFileAccess':
          final locator = args?['uri'] as String;
          expect(locator, document);
          checks.add(locator);
          if (!grant) throw PlatformException(code: 'permission_revoked');
          return null;
        case 'cancelScan':
          return null;
        default:
          fail('Unexpected scanner method: ${call.method}');
      }
    });
    final library = LibraryController(
      database: LibraryDatabase(NativeDatabase.memory()),
      source: const AndroidSafLibrarySource(),
      metadataReader: TagLibMetadataReader(
        readDescriptor: (fd) async {
          expect(fd, 77);
          return {'title': 'From SAF', 'durationMs': 1000};
        },
        closeDescriptor: closed.add,
      ),
    );
    addTearDown(library.close);
    await library.initialize();
    await _metadataIdle(library);
    expect(await library.addDirectory(), isTrue, reason: library.errorMessage);
    await _metadataIdle(library);
    final rootId = library.directories.single.id;
    final original = library.files.single;
    expect(original.metadata.title, 'From SAF');
    expect(original.metadata.durationMs, 1000);
    expect(closed, [-1, 77]); // Asset initialization sentinel, then owned FD.

    grant = false;
    final opened = <String>[];
    Future<void> play(LocalAudioFile file) async =>
        opened.add(file.location.locator);
    expect(await library.playFile(original.id, play), isFalse);
    expect(opened, isEmpty);
    expect(checks, [document]);
    expect(await library.scanDirectory(rootId), isFalse);
    expect(library.directories.single.isAccessible, isFalse);
    expect(library.files, isEmpty);
    await _metadataIdle(library);

    expect(await library.addDirectory(), isTrue, reason: library.errorMessage);
    await _metadataIdle(library);
    expect(library.directories.single.id, rootId);
    expect(library.directories.single.isAccessible, isTrue);
    final restored = library.files.single;
    expect(restored.id, original.id);
    expect(restored.revision, original.revision);
    expect(restored.metadata.title, original.metadata.title);
    expect(closed, [-1, 77]); // Unchanged, ready tags are not read again.
    expect(await library.playFile(restored.id, play), isTrue);
    expect(checks, [document, document]);
    expect(opened, [document]);
  });
}

Future<void> _metadataIdle(LibraryController library) async {
  if (!library.isReadingMetadata) return;
  final idle = Completer<void>();
  void changed() {
    if (!library.isReadingMetadata && !idle.isCompleted) idle.complete();
  }

  library.addListener(changed);
  try {
    await idle.future;
  } finally {
    library.removeListener(changed);
  }
}

class _DirectoryPicker extends FilePickerPlatform {
  _DirectoryPicker(this.choose);

  final Uri Function() choose;

  @override
  Future<Uri?> pickDirectory({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => choose();
}

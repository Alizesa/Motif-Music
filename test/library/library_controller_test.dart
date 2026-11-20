import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_platform_source.dart';

import '../support/library_fixtures.dart';

void main() {
  late LibraryDatabase database;
  late LibraryRepository repository;
  late FakeLibrarySource source;
  late LibraryController controller;
  late List<FileLocation> verified;

  setUp(() {
    database = LibraryDatabase(NativeDatabase.memory());
    repository = LibraryRepository(database);
    source = FakeLibrarySource();
    verified = [];
    controller = LibraryController(
      database: database,
      source: source,
      verifyFile: (location) async => verified.add(location),
    );
  });
  tearDown(() => controller.close());

  test(
    'initialization recovers interrupted scans once without retiring files',
    () async {
      final root = await repository.addDirectory(
        location: testDirectory.location,
        displayName: testDirectory.displayName,
      );
      final old = await repository.beginScan(root.id);
      await repository.writeScanBatch(old, [testAudio(1)]);
      await controller.initialize();
      expect(controller.initialized, isTrue);
      expect(controller.directories.single.lastScanState, 'interrupted');
      expect(controller.files.single.fileName, 'track-1.flac');
      final newScan = await repository.beginScan(root.id);
      await controller.initialize();
      expect(
        (await repository.directories()).single.activeGeneration,
        newScan.generation,
      );
    },
  );

  test(
    'adding a directory scans automatically and re-adding preserves IDs',
    () async {
      await controller.initialize();
      source.files = [testAudio(1), testAudio(2)];
      expect(await controller.addDirectory(), isTrue);
      final id = controller.files.first.id;
      expect(controller.files, hasLength(2));
      expect(controller.directories.single.lastScanState, 'complete');
      expect(controller.notice, contains('2'));
      expect(controller.files.first.metadata.state, MetadataState.pending);
      expect(await controller.addDirectory(), isTrue);
      expect(controller.directories, hasLength(1));
      expect(controller.files.first.id, id);
      expect(source.scanCalls, 2);
    },
  );

  test('cancelled directory picker changes neither roots nor files', () async {
    await controller.initialize();
    source.picked = null;
    await controller.addDirectory();
    expect(controller.directories, isEmpty);
    expect(controller.files, isEmpty);
    expect(source.scanCalls, 0);
  });

  test(
    'cursor navigation retains at most 100 rows and refresh resets its cursor',
    () async {
      await controller.initialize();
      source.files = List.generate(205, testAudio);
      controller.addListener(
        () => expect(controller.files.length, lessThanOrEqualTo(100)),
      );
      await controller.addDirectory();
      expect(controller.files.first.fileName, 'track-0.flac');
      expect(controller.hasNextPage, isTrue);
      await controller.nextPage();
      expect(controller.pageNumber, 2);
      expect(controller.files.first.fileName, 'track-100.flac');
      await controller.nextPage();
      expect(controller.files, hasLength(5));
      expect(controller.hasNextPage, isFalse);
      expect(controller.files.first.fileName, 'track-200.flac');
      await controller.previousPage();
      expect(controller.files.first.fileName, 'track-100.flac');
      await controller.refresh();
      expect(controller.pageNumber, 1);
      expect(controller.hasPreviousPage, isFalse);
      expect(controller.files.first.fileName, 'track-0.flac');
    },
  );

  for (final count in [0, 100, 101, 200]) {
    test('pagination has no empty extra page at $count files', () async {
      await controller.initialize();
      source.files = List.generate(count, testAudio);
      await controller.addDirectory();
      final seen = <int>[];
      do {
        seen.addAll(controller.files.map((file) => file.id));
        expect(controller.files.length, lessThanOrEqualTo(100));
        if (!controller.hasNextPage) break;
        expect(await controller.nextPage(), isTrue);
      } while (true);
      expect(seen, hasLength(count));
      expect(seen.toSet(), hasLength(count));
      expect(controller.pageNumber, count <= 100 ? 1 : 2);
      expect(await controller.nextPage(), isTrue);
      expect(controller.hasNextPage, isFalse);
      expect(controller.pageNumber, count <= 100 ? 1 : 2);
    });
  }

  test('manual rescan reflects additions, changes and missing files', () async {
    await controller.initialize();
    source.files = [testAudio(1), testAudio(2)];
    await controller.addDirectory();
    final retained = controller.files.last;
    source.files = [
      ObservedAudioFile(
        location: retained.location,
        fileName: retained.fileName,
        sizeBytes: 84,
        modifiedMs: 101,
      ),
      testAudio(3),
    ];
    expect(
      await controller.scanDirectory(controller.directories.single.id),
      isTrue,
    );
    expect(controller.files.map((file) => file.fileName), [
      'track-2.flac',
      'track-3.flac',
    ]);
    expect(controller.files.first.id, retained.id);
    expect(controller.files.first.revision, retained.revision + 1);
    expect(controller.files.first.metadata.state, MetadataState.pending);
    expect(source.scanCalls, 2);
    expect(controller.pageNumber, 1);
  });
  test('partial failure reloads persisted files and leaves existing members intact', () async {
    await controller.initialize();
    source.files = [testAudio(1)];
    await controller.addDirectory();
    final rootId = controller.directories.single.id;
    source.files = [testAudio(2)];
    source.traversalError = const LibraryTraversalException('subtree failed');
    expect(await controller.scanDirectory(rootId), isFalse);
    expect(controller.errorMessage, contains('subtree failed'));
    expect(controller.files, hasLength(2));
    expect(controller.directories.single.lastScanState, 'failed');
    expect(controller.directories.single.isAccessible, isTrue);
    expect(controller.isBusy, isFalse);
  });

  test(
    'revoked authorization is visible and re-adding restores the same root',
    () async {
      await controller.initialize();
      source.files = [testAudio(1)];
      await controller.addDirectory();
      final rootId = controller.directories.single.id;
      source.files = [];
      source.traversalError = const LibraryTraversalException(
        'grant revoked',
        rootAccessRevoked: true,
      );
      await controller.scanDirectory(rootId);
      expect(controller.directories.single.isAccessible, isFalse);
      expect(controller.files, isEmpty);
      source.traversalError = null;
      source.files = [testAudio(1)];
      await controller.addDirectory();
      expect(controller.directories.single.id, rootId);
      expect(controller.files, hasLength(1));
      expect(controller.directories.single.isAccessible, isTrue);
    },
  );

  test(
    'cancellation preserves committed batches and rejects competing actions',
    () async {
      await controller.initialize();
      source.files = List.generate(201, testAudio);
      final blocked = Completer<void>();
      source.beforeBatch = (batch, cancellation) async {
        if (batch == 1) {
          blocked.complete();
          await cancellation.whenCancelled;
        }
      };
      final scanning = controller.addDirectory();
      await blocked.future;
      expect(controller.isScanning, isTrue);
      expect(controller.indexedFiles, 200);
      expect(
        await controller.removeDirectory(controller.directories.single.id),
        isFalse,
      );
      expect(source.released, isEmpty);
      controller.cancelScan();
      expect(await scanning, isFalse);
      expect(controller.notice, contains('已取消'));
      expect(controller.directories.single.lastScanState, 'interrupted');
      expect((await repository.filesPage(limit: 200)), hasLength(200));
      expect(controller.files, hasLength(100));
      expect(controller.isBusy, isFalse);
    },
  );

  test(
    'removal releases only the chosen root and refreshes the page',
    () async {
      await controller.initialize();
      source.files = [testAudio(1)];
      await controller.addDirectory();
      final root = controller.directories.single;
      expect(await controller.removeDirectory(root.id), isTrue);
      expect(source.released.single.key, root.location.key);
      expect(controller.directories, isEmpty);
      expect(controller.files, isEmpty);
    },
  );

  test(
    'playback re-resolves one current record and checks its readable locator',
    () async {
      await controller.initialize();
      source.files = [testAudio(1), testAudio(2)];
      await controller.addDirectory();
      final selected = controller.files.last;
      LocalAudioFile? played;
      expect(
        await controller.playFile(selected.id, (file) async {
          played = file;
        }),
        isTrue,
      );
      expect(played!.id, selected.id);
      expect(verified.single.locator, selected.location.locator);
      await repository.removeDirectory(controller.directories.single.id);
      played = null;
      expect(
        await controller.playFile(selected.id, (file) async {
          played = file;
        }),
        isFalse,
      );
      expect(played, isNull);
      expect(verified, hasLength(1));
      expect(controller.errorMessage, contains('文件已移除'));
    },
  );

  test(
    'engine failures remain visible without losing the current page',
    () async {
      await controller.initialize();
      source.files = [testAudio(1)];
      await controller.addDirectory();
      expect(
        await controller.playFile(
          controller.files.single.id,
          (_) async => throw StateError('decoder failed'),
        ),
        isFalse,
      );
      expect(controller.errorMessage, contains('decoder failed'));
      expect(controller.files, hasLength(1));
      expect(controller.isBusy, isFalse);
    },
  );

  test(
    'closing detaches a pending picker and consumes its late error',
    () async {
      await controller.initialize();
      final picker = Completer<PickedLibraryDirectory?>();
      source.pickerFuture = picker.future;
      final picking = controller.addDirectory();
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.close().timeout(const Duration(seconds: 2));
      expect(await picking, isFalse);
      expect(notifications, 0);
      expect(identical(controller.close(), controller.close()), isTrue);
      picker.completeError(StateError('picker detached'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'closing during an access check prevents playback and consumes late errors',
    () async {
      await controller.close();
      final checking = Completer<void>();
      final accessResult = Completer<void>();
      controller = LibraryController(
        database: LibraryDatabase(NativeDatabase.memory()),
        source: source..files = [testAudio(1)],
        verifyFile: (_) {
          checking.complete();
          return accessResult.future;
        },
      );
      await controller.initialize();
      await controller.addDirectory();
      var played = false;
      final playing = controller.playFile(controller.files.single.id, (
        _,
      ) async {
        played = true;
      });
      await checking.future;
      await controller.close().timeout(const Duration(seconds: 2));
      expect(await playing, isFalse);
      expect(played, isFalse);
      accessResult.completeError(StateError('provider detached'));
      await Future<void>.delayed(Duration.zero);
    },
  );
  test('closing cancels a running scan before closing the database', () async {
    await controller.initialize();
    source.files = List.generate(201, testAudio);
    final blocked = Completer<void>();
    source.beforeBatch = (batch, cancellation) async {
      if (batch == 1) {
        blocked.complete();
        await cancellation.whenCancelled;
      }
    };
    final scanning = controller.addDirectory();
    await blocked.future;
    await controller.close();
    expect(await scanning, isFalse);
    expect(controller.notice, contains('已取消'));
  });

  test('unreadable files never reach the playback engine', () async {
    await controller.close();
    source.files = [testAudio(1)];
    controller = LibraryController(
      database: LibraryDatabase(NativeDatabase.memory()),
      source: source,
      verifyFile: (_) async => throw const FileSystemException('access denied'),
    );
    await controller.initialize();
    await controller.addDirectory();
    var played = false;
    expect(
      await controller.playFile(controller.files.single.id, (_) async {
        played = true;
      }),
      isFalse,
    );
    expect(played, isFalse);
    expect(controller.errorMessage, contains('access denied'));
  });
  test(
    'close and reopen through application controllers preserves the library',
    () async {
      await controller.close();
      final temp = await Directory.systemTemp.createTemp(
        'motif-controller-restart-',
      );
      final file = File('${temp.path}${Platform.pathSeparator}library.sqlite');
      var persistent = LibraryController(
        database: LibraryDatabase(NativeDatabase(file)),
        source: FakeLibrarySource()..files = [testAudio(42)],
        verifyFile: (_) async {},
      );
      try {
        await persistent.initialize();
        await persistent.addDirectory();
        final fileId = persistent.files.single.id;
        await persistent.close();
        persistent = LibraryController(
          database: LibraryDatabase(NativeDatabase(file)),
          source: FakeLibrarySource(),
          verifyFile: (_) async {},
        );
        await persistent.initialize();
        expect(persistent.files.single.id, fileId);
        expect(persistent.directories.single.lastScanState, 'complete');
      } finally {
        await persistent.close();
        await deleteTestDirectory(temp);
      }
    },
  );
}

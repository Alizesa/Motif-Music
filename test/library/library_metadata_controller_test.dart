import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';

import '../support/library_fixtures.dart';

void main() {
  late LibraryDatabase db;
  late LibraryRepository repository;
  late FakeLibrarySource source;
  LibraryController? controller;
  Completer<TrackMetadata>? gate;
  setUp(() async {
    controller = null;
    gate = null;
    db = LibraryDatabase(NativeDatabase.memory());
    repository = LibraryRepository(db);
    source = FakeLibrarySource()..files = [testAudio(1), testAudio(2)];
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) {
      gate!.complete(const TrackMetadata());
    }
    if (controller == null) {
      await db.close();
    } else {
      await controller!.close();
    }
  });
  LibraryController create(FakeMetadataReader reader) =>
      controller = LibraryController(
        database: db,
        source: source,
        metadataReader: reader,
        verifyFile: (_) async {},
      );
  Future<void> seed() async {
    final root = await repository.addDirectory(
      location: testDirectory.location,
      displayName: 'music',
    );
    final scan = await repository.beginScan(root.id);
    await repository.writeScanBatch(scan, source.files);
    await repository.completeScan(scan);
  }

  test(
    'startup resumes pending metadata while playback remains available',
    () async {
      await seed();
      gate = Completer<TrackMetadata>();
      final entered = Completer<void>();
      final reader = FakeMetadataReader((_) {
        if (!entered.isCompleted) entered.complete();
        return gate!.future;
      });
      final c = create(reader);
      await c.initialize();
      await entered.future;
      expect(c.isReadingMetadata, isTrue);
      expect(c.isBusy, isFalse);
      var played = false;
      expect(
        await c.playFile(c.files.first.id, (_) async {
          played = true;
        }),
        isTrue,
      );
      expect(played, isTrue);
      gate!.complete(const TrackMetadata(title: 'Tagged'));
      await c.startMetadata();
      expect(c.files.every((f) => f.metadata.title == 'Tagged'), isTrue);
      expect(reader.maxActive, 1);
      expect(reader.calls, [1, 2]);
    },
  );

  test(
    'postscan automatic extraction and unchanged scan skip ready files',
    () async {
      final reader = FakeMetadataReader(
        (_) async => const TrackMetadata(title: 'Tagged'),
      );
      final c = create(reader);
      await c.initialize();
      await c.addDirectory();
      await c.startMetadata();
      expect(reader.calls, [1, 2]);
      await c.scanDirectory(c.directories.single.id);
      await c.startMetadata();
      expect(reader.calls, [1, 2]);
      expect(c.files.first.metadata.title, 'Tagged');
    },
  );

  test(
    'cancellation discards late result and explicit resume processes pending',
    () async {
      await seed();
      gate = Completer<TrackMetadata>();
      final entered = Completer<void>();
      var blocked = true;
      final reader = FakeMetadataReader((_) {
        if (!entered.isCompleted) entered.complete();
        return blocked
            ? gate!.future
            : Future.value(const TrackMetadata(title: 'Resumed'));
      });
      final c = create(reader);
      await c.initialize();
      await entered.future;
      c.cancelMetadata();
      expect(c.isMetadataCancelling, isTrue);
      gate!.complete(const TrackMetadata(title: 'Ignored'));
      // Do not request another pass until the cancelled one has finished.
      while (c.isReadingMetadata) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.files.first.metadata.state, MetadataState.pending);
      blocked = false;
      await c.startMetadata();
      expect(c.files.first.metadata.title, 'Resumed');
      expect(reader.calls, [1, 1, 2]);
      expect(reader.maxActive, 1);
    },
  );

  test(
    'removal during extraction prevents stale writes and further reads',
    () async {
      await seed();
      gate = Completer<TrackMetadata>();
      final entered = Completer<void>();
      final reader = FakeMetadataReader((_) {
        entered.complete();
        return gate!.future;
      });
      final c = create(reader);
      await c.initialize();
      await entered.future;
      expect(await c.removeDirectory(c.directories.single.id), isTrue);
      gate!.complete(const TrackMetadata(title: 'Removed'));
      await c.startMetadata();
      expect(c.files, isEmpty);
      expect(reader.calls, [1]);
      expect(reader.maxActive, 1);
    },
  );

  test(
    'close waits for active reader cleanup and discards its late error',
    () async {
      await seed();
      gate = Completer<TrackMetadata>();
      final entered = Completer<void>();
      final reader = FakeMetadataReader((_) {
        entered.complete();
        return gate!.future;
      });
      final c = create(reader);
      await c.initialize();
      await entered.future;
      var closed = false;
      final closing = c.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      gate!.completeError(StateError('late parse error'));
      await closing;
      expect(reader.active, 0);
      expect(reader.calls, [1]);
      await c.close();
    },
  );
  test(
    'explicit retry rereads failed items while ordinary resume does not',
    () async {
      await seed();
      var fail = true;
      final reader = FakeMetadataReader((file) async {
        if (file.id == 1 && fail) throw StateError('unreadable tags');
        return TrackMetadata(title: 'Song ${file.id}');
      });
      final c = create(reader);
      await c.initialize();
      await c.startMetadata();
      expect(c.files.first.metadata.state, MetadataState.failed);
      fail = false;
      await c.startMetadata();
      expect(reader.calls, [1, 2]);
      await c.startMetadata(retryFailed: true);
      expect(reader.calls, [1, 2, 1]);
      expect(c.files.first.metadata.title, 'Song 1');
    },
  );

  test('rescan during a pending read resumes with a fresh snapshot and one active reader', () async {
    await seed();
    gate = Completer<TrackMetadata>();
    final entered = Completer<void>();
    var first = true;
    final reader = FakeMetadataReader((_) {
      if (first) {
        first = false;
        entered.complete();
        return gate!.future;
      }
      return Future.value(const TrackMetadata(title: 'Fresh'));
    });
    final c = create(reader);
    await c.initialize();
    await entered.future;
    final observed = testAudio(1);
    source.files = [
      ObservedAudioFile(
        location: observed.location,
        fileName: observed.fileName,
        sizeBytes: 43,
        modifiedMs: 101,
      ),
    ];
    expect(await c.scanDirectory(c.directories.single.id), isTrue);
    gate!.complete(const TrackMetadata(title: 'Old'));
    await c.startMetadata();
    expect(c.files, hasLength(1));
    expect(c.files.single.sizeBytes, 43);
    expect(c.files.single.metadata.title, 'Fresh');
    expect(reader.calls, [1, 1]);
    expect(reader.maxActive, 1);
  });
}

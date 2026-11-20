import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_metadata_service.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_metadata_reader.dart';
import 'package:motif/library/platform/library_platform_source.dart';

import '../support/library_fixtures.dart';

class CallbackMetadataReader implements LibraryMetadataReader {
  CallbackMetadataReader(this.callback);
  final Future<TrackMetadata> Function(LocalAudioFile) callback;
  @override
  Future<TrackMetadata> read(LocalAudioFile file) => callback(file);
}

void main() {
  late LibraryDatabase db;
  late LibraryRepository repository;
  late LibraryDirectory root;
  setUp(() async {
    db = LibraryDatabase(NativeDatabase.memory());
    repository = LibraryRepository(db);
    root = await repository.addDirectory(
      location: testDirectory.location,
      displayName: 'music',
    );
    final scan = await repository.beginScan(root.id);
    await repository.writeScanBatch(scan, [
      testAudio(1),
      testAudio(2),
      testAudio(3),
    ]);
    await repository.completeScan(scan);
  });
  tearDown(() => db.close());

  test('sequential extraction continues past failure and only explicit retry rereads failures', () async {
    final calls = <int>[];
    var active = 0;
    var maxActive = 0;
    final reader = CallbackMetadataReader((file) async {
      calls.add(file.id);
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(Duration.zero);
      active--;
      if (file.id == 2) throw StateError('bad tag');
      return TrackMetadata(title: 'title-${file.id}');
    });
    final service = LibraryMetadataService(repository, reader);
    final result = await service.run(cancellation: LibraryScanCancellation());
    expect(result.processed, 3);
    expect(result.failed, 1);
    expect(maxActive, 1);
    expect(calls, [1, 2, 3]);
    await service.run(cancellation: LibraryScanCancellation());
    expect(calls, [1, 2, 3]);
    await service.run(
      cancellation: LibraryScanCancellation(),
      includeFailed: true,
    );
    expect(calls, [1, 2, 3, 2]);
  });

  test('cancel consumes a late success and prevents both writeback and further dispatch', () async {
    final gate = Completer<TrackMetadata>();
    final entered = Completer<void>();
    final calls = <int>[];
    final cancellation = LibraryScanCancellation();
    final service = LibraryMetadataService(
      repository,
      CallbackMetadataReader((file) {
        calls.add(file.id);
        entered.complete();
        return gate.future;
      }),
    );
    final task = service.run(cancellation: cancellation);
    await entered.future;
    cancellation.cancel();
    gate.complete(const TrackMetadata(title: 'late'));
    expect((await task).processed, 0);
    expect(calls, [1]);
    expect(
      (await repository.filesPage()).every(
        (f) => f.metadata.state == MetadataState.pending,
      ),
      isTrue,
    );
  });

  test(
    'cancel consumes a late failure without marking the file failed',
    () async {
      final gate = Completer<TrackMetadata>();
      final entered = Completer<void>();
      final cancellation = LibraryScanCancellation();
      final task = LibraryMetadataService(
        repository,
        CallbackMetadataReader((_) {
          entered.complete();
          return gate.future;
        }),
      ).run(cancellation: cancellation);
      await entered.future;
      cancellation.cancel();
      gate.completeError(StateError('late error'));
      await task;
      expect(
        (await repository.filesPage()).first.metadata.state,
        MetadataState.pending,
      );
    },
  );

  test('a completed rescan rejects the old snapshot while preserving newly observed stats', () async {
    var first = true;
    final result = await LibraryMetadataService(
      repository,
      CallbackMetadataReader((file) async {
        if (first) {
          first = false;
          final scan = await repository.beginScan(root.id);
          await repository.writeScanBatch(scan, [
            testAudio(1),
            testAudio(2),
            testAudio(3),
          ]);
          await repository.completeScan(scan);
        }
        return const TrackMetadata(title: 'stale');
      }),
    ).run(cancellation: LibraryScanCancellation());
    expect(result.discarded, 3);
    expect(result.processed, 0);
  });

  test('cancelled task does no extraction even with pending records', () async {
    final token = LibraryScanCancellation()..cancel();
    final result = await LibraryMetadataService(
      repository,
      CallbackMetadataReader((_) async => throw StateError('must not run')),
    ).run(cancellation: token);
    expect(result.processed, 0);
  });
}

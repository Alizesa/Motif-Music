import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_controller.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/library_playback_error.dart';

import '../support/library_fixtures.dart';

void main() {
  late FakeLibrarySource source;
  late LibraryController library;
  late Future<void> Function(FileLocation) verify;

  setUp(() async {
    source = FakeLibrarySource()..files = [testAudio(1)];
    verify = (_) async {};
    library = LibraryController(
      database: LibraryDatabase(NativeDatabase.memory()),
      source: source,
      verifyFile: (location) => verify(location),
    );
    await library.initialize();
    await library.addDirectory();
  });

  tearDown(() => library.close());

  test(
    'playback preparation rechecks access and preserves the revision',
    () async {
      final expected = library.files.single;
      var calls = 0;
      verify = (_) async {
        calls++;
      };
      final prepared = await library.preparePlaybackFile(expected);
      expect(calls, 1);
      expect(prepared.id, expected.id);
      expect(prepared.revision, expected.revision);
    },
  );

  test('lost access is distinguished from a busy index', () async {
    verify = (_) async => throw StateError('lost grant');
    await expectLater(
      library.preparePlaybackFile(library.files.single),
      throwsA(
        isA<LibraryPlaybackException>().having(
          (error) => error.kind,
          'kind',
          LibraryPlaybackErrorKind.unavailable,
        ),
      ),
    );
  });

  test(
    'revision changes during the access check require a fresh match',
    () async {
      final expected = library.files.single;
      final original = source.files.single;
      verify = (_) async {
        source.files = [
          ObservedAudioFile(
            location: original.location,
            fileName: original.fileName,
            sizeBytes: original.sizeBytes,
            modifiedMs: 200,
          ),
        ];
        await library.scanDirectory(library.directories.single.id);
      };
      await expectLater(
        library.preparePlaybackFile(expected),
        throwsA(
          isA<LibraryPlaybackException>().having(
            (error) => error.kind,
            'kind',
            LibraryPlaybackErrorKind.changed,
          ),
        ),
      );
    },
  );

  test(
    'closing while checking access prevents a late playable result',
    () async {
      final pending = Completer<void>();
      final entered = Completer<void>();
      verify = (_) {
        entered.complete();
        return pending.future;
      };
      final checking = library.preparePlaybackFile(library.files.single);
      final expectedError = expectLater(
        checking,
        throwsA(isA<LibraryPlaybackException>()),
      );
      await entered.future;
      final closing = library.close();
      pending.complete();
      await expectedError;
      await closing;
    },
  );
}

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/application/library_scan_service.dart';
import 'package:motif/library/data/library_database.dart';
import 'package:motif/library/data/library_repository.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/android_saf_library_source.dart';
import 'package:motif/library/platform/library_platform_source.dart';
import 'package:motif/library/platform/windows_library_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows real-directory rescans retain IDs and retire only missing files',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'motif-scan-integration-',
      );
      final database = LibraryDatabase(NativeDatabase.memory());
      try {
        final keep = File('${temp.path}${Platform.pathSeparator}keep.M4A');
        final gone = File('${temp.path}${Platform.pathSeparator}gone.ogg');
        await keep.writeAsBytes([1, 2, 3]);
        await gone.writeAsBytes([4, 5, 6]);
        final repository = LibraryRepository(database);
        final root = await repository.addDirectory(
          location: FileLocation(
            platform: LibraryPlatform.windows,
            key: 'integration-root',
            locator: Uri.directory(temp.path).toString(),
          ),
          displayName: 'Music',
        );
        final service = LibraryScanService(
          repository,
          const WindowsLibrarySource(),
        );
        expect(await service.scanDirectory(root.id), 2);
        final original = (await repository.filesPage()).firstWhere(
          (file) => file.fileName == 'keep.M4A',
        );
        expect(await service.scanDirectory(root.id), 2);
        final unchanged = (await repository.filesPage()).firstWhere(
          (file) => file.fileName == 'keep.M4A',
        );
        expect(unchanged.id, original.id);
        expect(unchanged.revision, original.revision);

        await gone.delete();
        await keep.writeAsBytes([1, 2, 3, 4]);
        expect(await service.scanDirectory(root.id), 1);
        final remaining = (await repository.filesPage()).single;
        expect(remaining.id, original.id);
        expect(remaining.revision, greaterThan(original.revision));
        expect(remaining.sizeBytes, 4);
        expect(remaining.metadata.state, MetadataState.pending);
        expect(
          (await repository.directories()).single.lastScanState,
          'complete',
        );
      } finally {
        await database.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'Android channel failure after a committed batch preserves unseen members',
    () async {
      const channel = MethodChannel('motif/library_scanner');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final database = LibraryDatabase(NativeDatabase.memory());
      try {
        final repository = LibraryRepository(database);
        final root = await repository.addDirectory(
          location: const FileLocation(
            platform: LibraryPlatform.android,
            key: 'provider|root',
            locator: 'content://provider/tree/root',
          ),
          displayName: 'Music',
        );
        final initial = await repository.beginScan(root.id);
        await repository.writeScanBatch(initial, [
          const ObservedAudioFile(
            location: FileLocation(
              platform: LibraryPlatform.android,
              key: 'provider|existing',
              locator: 'content://provider/tree/root/document/existing',
            ),
            fileName: 'existing.flac',
          ),
        ]);
        await repository.completeScan(initial);
        var requests = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'nextBatch') return null;
          if (++requests == 1) {
            return {
              'type': 'batch',
              'files': [
                {
                  'key': 'provider|new',
                  'locator': 'content://provider/tree/root/document/new',
                  'fileName': 'new.opus',
                },
              ],
            };
          }
          // A subtree failed while the root grant remains valid.
          throw PlatformException(
            code: 'scan_failed',
            message: 'Incomplete subtree',
          );
        });
        final service = LibraryScanService(
          repository,
          const AndroidSafLibrarySource(),
        );
        await expectLater(
          service.scanDirectory(root.id),
          throwsA(isA<LibraryTraversalException>()),
        );
        expect(
          (await repository.filesPage()).map((file) => file.fileName),
          containsAll(['existing.flac', 'new.opus']),
        );
        final failed = (await repository.directories()).single;
        expect(failed.lastScanState, 'failed');
        expect(failed.isAccessible, isTrue);
        expect(failed.activeGeneration, isNull);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        await database.close();
      }
    },
  );
}

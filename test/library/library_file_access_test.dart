import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_file_access.dart';

import '../support/library_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('motif/library_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'Windows read probe closes its handle and fails after deletion',
    () async {
      final temp = await Directory.systemTemp.createTemp('motif-read-probe-');
      try {
        final file = File('${temp.path}${Platform.pathSeparator}song.flac');
        await file.writeAsBytes([1, 2, 3]);
        final location = FileLocation(
          platform: LibraryPlatform.windows,
          key: 'probe',
          locator: file.uri.toString(),
        );
        await verifyLibraryFileAccess(location);
        await file.delete();
        await expectLater(
          verifyLibraryFileAccess(location),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await deleteTestDirectory(temp);
      }
    },
  );

  test('Windows rejects a content locator before attempting file IO', () async {
    await expectLater(
      verifyLibraryFileAccess(
        const FileLocation(
          platform: LibraryPlatform.windows,
          key: 'bad',
          locator: 'content://provider/song',
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'Android passes the exact tree-specific content URI to its native probe',
    () async {
      MethodCall? observed;
      messenger.setMockMethodCallHandler(channel, (call) async {
        observed = call;
        return null;
      });
      const uri = 'content://provider/tree/root/document/root%2Fsong.oga';
      await verifyLibraryFileAccess(
        const FileLocation(
          platform: LibraryPlatform.android,
          key: 'provider|root/song.oga',
          locator: uri,
        ),
      );
      expect(observed!.method, 'checkFileAccess');
      expect((observed!.arguments as Map)['uri'], uri);
    },
  );

  test('Android access failures propagate to the controller', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'permission_revoked',
        message: 'Grant revoked',
      );
    });
    await expectLater(
      verifyLibraryFileAccess(
        const FileLocation(
          platform: LibraryPlatform.android,
          key: 'provider|song',
          locator: 'content://provider/song',
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'Android rejects non-content locations before invoking native code',
    () async {
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        nativeCalls++;
        return null;
      });
      await expectLater(
        verifyLibraryFileAccess(
          const FileLocation(
            platform: LibraryPlatform.android,
            key: 'bad',
            locator: 'https://example.com/song.flac',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(nativeCalls, 0);
    },
  );
}

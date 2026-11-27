import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/downloads/download_directory_store.dart';

void main() {
  late Directory root;
  late File settings;
  late FileDownloadDirectoryStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('motif-directory-settings-');
    settings = File.fromUri(root.uri.resolve('private/dir.json'));
    store = FileDownloadDirectoryStore(() async => settings);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'only the chosen locator survives a fresh store and replacement',
    () async {
      expect(await store.load(), isNull);
      for (final uri in [
        Uri.directory(r'C:\音乐 # %\files', windows: true),
        Uri.parse('content://provider/tree/primary%3AMusic%2FMore'),
      ]) {
        await store.save(uri);
        expect(
          await FileDownloadDirectoryStore(() async => settings).load(),
          uri,
        );
        expect(jsonDecode(await settings.readAsString()), {
          'version': 1,
          'uri': uri.toString(),
        });
        expect(settings.parent.listSync(), hasLength(1));
      }
    },
  );
  test(
    'rejects corrupted, oversized and non-directory locator settings',
    () async {
      final good = Uri.directory(r'D:\music', windows: true);
      await store.save(good);
      await expectLater(
        store.save(Uri.https('media.invalid', '/a')),
        throwsFormatException,
      );
      expect(await store.load(), good);
      for (final text in [
        '{',
        jsonEncode({'version': 2, 'uri': good.toString()}),
        jsonEncode({'version': 1, 'uri': 'file:relative'}),
        jsonEncode({
          'version': 1,
          'uri': 'content://provider/document/unselected',
        }),
        'x' * (512 * 1024 + 1),
      ]) {
        await settings.writeAsString(text);
        await expectLater(store.load(), throwsFormatException);
      }
      await store.save(good);
      expect(await store.load(), good);
    },
  );
}

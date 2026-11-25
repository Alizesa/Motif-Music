import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'LX script bridge preserves the upstream callback and byte contracts',
    () async {
      final result = await Process.run(
        Platform.isWindows ? 'node.exe' : 'node',
        ['test/online/lx_request_bridge_checks.mjs'],
        runInShell: false,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout.toString(), contains('PASS LX mobile/desktop'));
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

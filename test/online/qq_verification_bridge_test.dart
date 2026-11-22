import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('verification bridge handles visibility, native readiness and parent completion', () async {
    final result = await Process.run('node', [
      'test/online/qq_verification_bridge_checks.mjs',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}

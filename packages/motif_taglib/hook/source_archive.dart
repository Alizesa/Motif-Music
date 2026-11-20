import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Reuses only verified bytes and repairs a partial cache without trusting it.
/// Failed transfers never replace the cache or survive as a future cache hit.
Future<Uint8List> loadVerifiedSourceArchive({
  required File cache,
  required Uri source,
  required String expectedSha256,
}) async {
  bool isVerified(List<int> bytes) =>
      sha256.convert(bytes).toString() == expectedSha256;

  if (await cache.exists()) {
    final bytes = await cache.readAsBytes();
    if (isVerified(bytes)) return bytes;
  }

  await cache.parent.create(recursive: true);
  // The unique directory keeps partial data separate from both the cache and
  // other hook invocations; rename stays on the cache's filesystem.
  final temporary = await cache.parent.createTemp('.motif-taglib-source-');
  final download = File.fromUri(temporary.uri.resolve('source.zip'));
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
  try {
    final response = await (await client.getUrl(source)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Source download failed: ${response.statusCode}',
        uri: source,
      );
    }
    final destination = await download.open(mode: FileMode.write);
    try {
      await for (final chunk in response) {
        await destination.writeFrom(chunk);
      }
    } finally {
      await destination.close();
    }
    final bytes = await download.readAsBytes();
    if (!isVerified(bytes)) {
      throw StateError(
        'Source SHA-256 mismatch: ${cache.uri.pathSegments.last}',
      );
    }
    // Only fully downloaded, verified bytes may replace an existing cache.
    await download.rename(cache.path);
    return bytes;
  } finally {
    client.close(force: true);
    if (await download.exists()) await download.delete();
    await temporary.delete();
  }
}

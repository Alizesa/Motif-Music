import '../../../audio/controlled_pcm.dart';
import '../lx_http_connection.dart';
import 'lx_fixture_wave.dart';

/// The built-in test only opens its pinned HTTPS asset.
final class LxFixtureHttpsTransport implements FixtureRangeTransport {
  const LxFixtureHttpsTransport();

  static final _asset = Uri.parse(lxFixtureWaveUrl);

  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async {
    if (offset < 0 ||
        offset >= 256 * 1024 * 1024 ||
        (offset == 0 && validator != null) ||
        (offset != 0 &&
            (validator == null ||
                !RegExp(r'^"[\x21\x23-\x7e]{1,126}"$').hasMatch(validator)))) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    final wire = await openLxHttps(
      _asset,
      'GET',
      {
        'User-Agent': 'Motif-LX-fixture/1',
        'Accept': 'audio/wav, application/octet-stream',
        'Range': 'bytes=$offset-',
        'If-Range': ?validator,
      },
      null,
      cancellation,
    );
    return FixtureRangeResponse(
      status: wire.status,
      headers: wire.headers,
      body: wire.body,
    );
  }
}

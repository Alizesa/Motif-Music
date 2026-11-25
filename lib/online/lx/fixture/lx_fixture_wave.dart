import 'dart:typed_data';

import '../../../audio/controlled_pcm.dart';

// This is the only asset authorised by the in-app fixture. General script
// grants, redirects and other media formats belong to later integration.
const lxFixtureWaveUrl =
    'https://raw.githubusercontent.com/jiaaro/pydub/'
    '103e339d3bc7a9a58a9f1de65f7d8074659b5f5a/test/data/test-dc_offset.wav';
const lxFixtureTrackTitle = 'LX 测试音频';
const _headerBytes = 44;
const _maximumWave = 256 * 1024 * 1024;

enum FixtureMediaFailure { denied, transport, range, format, truncated }

final class FixtureMediaException implements Exception {
  const FixtureMediaException(this.kind);
  final FixtureMediaFailure kind;
}

abstract interface class FixtureRangeTransport {
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  );
}

final class FixtureRangeResponse {
  FixtureRangeResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, List<String>> headers;
  final ControlledPcmRead body;
}

/// Verify the RIFF envelope before exposing only its PCM payload. A seek
/// creates a new reader for the same checked representation.
final class FixtureWave implements ControlledPcmInput {
  FixtureWave._(this._transport, this._initial, this._description, this._tag);

  final FixtureRangeTransport _transport;
  final _WaveDescription _description;
  final String _tag;
  ControlledPcmRead? _initial;
  final _readers = <_WaveRead>{};
  bool _closed = false;

  static Future<FixtureWave> open(
    String address,
    FixtureRangeTransport transport,
    PcmCancellation cancellation,
  ) async {
    if (address != lxFixtureWaveUrl) {
      throw const FixtureMediaException(FixtureMediaFailure.denied);
    }
    return openManaged(transport, cancellation);
  }

  /// The transport owns the URL and checks the current grant on every open.
  static Future<FixtureWave> openManaged(
    FixtureRangeTransport transport,
    PcmCancellation cancellation,
  ) async {
    cancellation.check();
    final response = await cancellation.until(
      transport.open(0, null, cancellation),
      discard: (late) => late.body.close(),
    );
    try {
      cancellation.check();
      final envelope = _envelope(response, 0);
      final prefix = Uint8List(_headerBytes);
      var filled = 0;
      while (filled < _headerBytes) {
        final part = await cancellation.until(
          response.body.read(_headerBytes - filled),
        );
        if (part.isEmpty || part.length > _headerBytes - filled) {
          throw const FixtureMediaException(FixtureMediaFailure.truncated);
        }
        prefix.setRange(filled, filled + part.length, part);
        filled += part.length;
      }
      final description = _WaveDescription.parse(prefix, envelope.size);
      cancellation.check();
      return FixtureWave._(transport, response.body, description, envelope.tag);
    } catch (_) {
      response.body.close();
      rethrow;
    }
  }

  @override
  int get channels => _description.channels;
  @override
  int get sampleRate => _description.rate;
  @override
  int get frames => (_description.size - _headerBytes) ~/ (channels * 2);
  @override
  bool get seekable => !_closed;

  @override
  Future<ControlledPcmRead> openAt(
    int frame,
    PcmCancellation cancellation,
  ) async {
    cancellation.check();
    if (_closed) throw const PcmCancelled();
    if (frame < 0 || frame >= frames) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    final offset = _headerBytes + frame * channels * 2;
    var body = _initial;
    _initial = null;
    if (body == null || frame != 0) {
      body?.close();
      final response = await cancellation.until(
        _transport.open(offset, _tag, cancellation),
        discard: (late) => late.body.close(),
      );
      try {
        final envelope = _envelope(response, offset);
        if (envelope.size != _description.size || envelope.tag != _tag) {
          throw const FixtureMediaException(FixtureMediaFailure.range);
        }
        cancellation.check();
        if (_closed) throw const PcmCancelled();
        body = response.body;
      } catch (_) {
        response.body.close();
        rethrow;
      }
    }
    final reader = _WaveRead(this, body, _description.size - offset);
    _readers.add(reader);
    return reader;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _initial?.close();
    _initial = null;
    for (final reader in _readers.toList(growable: false)) {
      reader.close();
    }
  }
}

({int size, String tag}) _envelope(FixtureRangeResponse response, int offset) {
  String? single(String name) {
    final values = response.headers[name];
    if (values == null) return null;
    if (values.length != 1) {
      throw const FixtureMediaException(FixtureMediaFailure.range);
    }
    return values.single;
  }

  final range = RegExp(r'^bytes (\d{1,10})-(\d{1,10})/(\d{1,10})$')
      .firstMatch(single('content-range') ?? '');
  final length = int.tryParse(single('content-length') ?? '');
  final encoding = single('content-encoding');
  final tag = single('etag');
  if (response.status != 206 ||
      range == null ||
      length == null ||
      (encoding != null && encoding.toLowerCase() != 'identity') ||
      response.headers.containsKey('transfer-encoding') ||
      tag == null ||
      !RegExp(r'^"[\x21\x23-\x7e]{1,126}"$').hasMatch(tag)) {
    throw const FixtureMediaException(FixtureMediaFailure.range);
  }
  final start = int.parse(range[1]!);
  final end = int.parse(range[2]!);
  final size = int.parse(range[3]!);
  if (start != offset ||
      end != size - 1 ||
      size <= offset ||
      size <= _headerBytes ||
      size > _maximumWave ||
      length != size - start) {
    throw const FixtureMediaException(FixtureMediaFailure.range);
  }
  final type = single('content-type')?.split(';').first.trim().toLowerCase();
  if (!const {
    'audio/wav',
    'audio/x-wav',
    'application/octet-stream',
  }.contains(type)) {
    throw const FixtureMediaException(FixtureMediaFailure.format);
  }
  return (size: size, tag: tag);
}

final class _WaveDescription {
  const _WaveDescription(this.rate, this.channels, this.size);
  final int rate;
  final int channels;
  final int size;

  factory _WaveDescription.parse(Uint8List prefix, int size) {
    final data = ByteData.sublistView(prefix);
    int word(int offset) => data.getUint16(offset, Endian.little);
    int dword(int offset) => data.getUint32(offset, Endian.little);
    String text(int offset, int length) =>
        String.fromCharCodes(prefix.getRange(offset, offset + length));
    final channels = word(22);
    final rate = dword(24);
    final frame = channels * 2;
    if (text(0, 4) != 'RIFF' ||
        text(8, 8) != 'WAVEfmt ' ||
        text(36, 4) != 'data' ||
        dword(4) != size - 8 ||
        dword(16) != 16 ||
        word(20) != 1 ||
        (channels != 1 && channels != 2) ||
        rate < 8000 ||
        rate > 192000 ||
        dword(28) != rate * frame ||
        word(32) != frame ||
        word(34) != 16 ||
        dword(40) != size - _headerBytes ||
        (size - _headerBytes) % frame != 0) {
      throw const FixtureMediaException(FixtureMediaFailure.format);
    }
    return _WaveDescription(rate, channels, size);
  }
}

final class _WaveRead implements ControlledPcmRead {
  _WaveRead(this.owner, this.body, this.remaining);
  final FixtureWave owner;
  final ControlledPcmRead body;
  int remaining;
  bool closed = false;

  @override
  Future<Uint8List> read(int maximum) async {
    if (maximum < 1 || maximum > 32 * 1024) {
      throw RangeError.range(maximum, 1, 32 * 1024);
    }
    if (remaining == 0) return Uint8List(0);
    if (closed) throw const PcmCancelled();
    final limit = maximum < remaining ? maximum : remaining;
    final part = await body.read(limit);
    if (closed) throw const PcmCancelled();
    if (part.isEmpty || part.length > limit) {
      close();
      throw const FixtureMediaException(FixtureMediaFailure.truncated);
    }
    remaining -= part.length;
    if (remaining == 0) close();
    return part;
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    owner._readers.remove(this);
    body.close();
  }
}

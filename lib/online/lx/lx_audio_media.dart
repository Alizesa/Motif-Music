import 'dart:typed_data';

import '../../audio/controlled_encoded.dart';
import '../../audio/controlled_pcm.dart';
import 'fixture/lx_fixture_wave.dart';
import '../domain/online_error.dart';

const _maximumMediaBytes = 512 * 1024 * 1024;
const _maximumMetadata = 16 * 1024 * 1024;
const _formatError = FixtureMediaException(FixtureMediaFailure.format);
const _rangeError = FixtureMediaException(FixtureMediaFailure.range);

/// Detect actual bytes, never a URL suffix or the requested quality tier.
Future<ControlledAudioInput> openLxAudio(
  FixtureRangeTransport transport,
  PcmCancellation cancellation, {
  bool sequential = false,
}) async {
  final first = await cancellation.until(
    transport.open(0, null, cancellation),
    discard: (late) => late.body.close(),
  );
  try {
    if (first.status == 429) {
      throw const OnlineException(OnlineErrorKind.rateLimited);
    }
    if (!const {200, 206}.contains(first.status)) {
      throw const OnlineException(OnlineErrorKind.operationRejected);
    }
    final envelope = _envelope(first, 0);
    final probe = _Probe(first.body, cancellation);
    final magic = await probe.read(4);
    if (_text(magic) == 'RIFF') {
      return await FixtureWave.openManaged(
        _FirstResponse(
          transport,
          FixtureRangeResponse(
            status: first.status,
            headers: first.headers,
            body: _PrefixRead(magic, first.body),
          ),
        ),
        cancellation,
        sequential: sequential,
      );
    }
    final ControlledAudioFormat format;
    final Uint8List header;
    final Uint8List audio;
    final int dataOffset;
    if (_text(magic) == 'fLaC') {
      format = ControlledAudioFormat.flac;
      var block = await probe.read(4);
      if ((block[0] & 0x7f) != 0 || _size24(block, 1) != 34) throw _formatError;
      final info = await probe.read(34);
      final values = ByteData.sublistView(info);
      final minimum = values.getUint16(0);
      final maximum = values.getUint16(2);
      final packed = values.getUint64(10);
      final rate = packed >> 44;
      final channels = ((packed >> 41) & 7) + 1;
      final bits = ((packed >> 36) & 31) + 1;
      if (minimum < 16 ||
          maximum < minimum ||
          rate < 8000 ||
          rate > 384000 ||
          channels > 8 ||
          bits < 8 ||
          bits > 32) {
        throw _formatError;
      }
      var blocks = 1;
      while (block[0] & 0x80 == 0) {
        if (++blocks > 128) throw _formatError;
        block = await probe.read(4);
        if ((block[0] & 0x7f) == 0 || (block[0] & 0x7f) == 127) {
          throw _formatError;
        }
        await probe.skip(_size24(block, 1));
        if (probe.offset > _maximumMetadata) throw _formatError;
      }
      dataOffset = probe.offset;
      audio = await probe.read(4);
      if (audio[0] != 255 || (audio[1] & 0xfe) != 0xf8) throw _formatError;
      // Drop optional tags, artwork and reference metadata. The decoder only
      // needs STREAMINFO and the audio frames, all read from this one resource.
      header = Uint8List.fromList([...magic, 0x80, 0, 0, 34, ...info]);
    } else {
      format = ControlledAudioFormat.mp3;
      var frame = magic;
      if (_text(magic.sublist(0, 3)) == 'ID3') {
        final rest = await probe.read(6);
        if (!const {2, 3, 4}.contains(magic[3]) ||
            rest[0] == 255 ||
            rest.skip(2).any((byte) => byte & 0x80 != 0)) {
          throw _formatError;
        }
        final size = rest
            .skip(2)
            .fold<int>(0, (size, byte) => (size << 7) | byte);
        if (size > _maximumMetadata) throw _formatError;
        await probe.skip(
          size + (magic[3] == 4 && rest[1] & 0x10 != 0 ? 10 : 0),
        );
        frame = await probe.read(4);
      }
      dataOffset = probe.offset - 4;
      final firstFrame = _Mp3Frame.parse(frame);
      final following = await probe.read(firstFrame.size);
      final next = _Mp3Frame.parse(following.sublist(following.length - 4));
      if (next.version != firstFrame.version || next.rate != firstFrame.rate) {
        throw _formatError;
      }
      audio = Uint8List.fromList([...frame, ...following]);
      header = Uint8List(0);
    }
    if (dataOffset + audio.length >= envelope.size) throw _formatError;
    cancellation.check();
    return _EncodedAudio(
      transport,
      format,
      envelope.size,
      dataOffset,
      header,
      envelope.tag,
      envelope.ranges && envelope.tag != null,
      _PrefixRead(Uint8List.fromList([...header, ...audio]), first.body),
    );
  } catch (_) {
    first.body.close();
    rethrow;
  }
}

String _text(List<int> bytes) => String.fromCharCodes(bytes);
int _size24(List<int> bytes, int offset) =>
    (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];

final class _Mp3Frame {
  const _Mp3Frame(this.version, this.rate, this.size);
  final int version, rate, size;
  factory _Mp3Frame.parse(List<int> bytes) {
    if (bytes.length != 4 ||
        bytes[0] != 255 ||
        bytes[1] & 0xe0 != 0xe0 ||
        (bytes[1] >> 1) & 3 != 1) {
      throw _formatError;
    }
    final version = (bytes[1] >> 3) & 3;
    final bitrate = bytes[2] >> 4;
    final sample = (bytes[2] >> 2) & 3;
    if (version == 1 || bitrate == 0 || bitrate == 15 || sample == 3) {
      throw _formatError;
    }
    final rate =
        const [44100, 48000, 32000][sample] ~/
        (version == 3
            ? 1
            : version == 2
            ? 2
            : 4);
    final kbps = (version == 3
        ? const [
            0,
            32,
            40,
            48,
            56,
            64,
            80,
            96,
            112,
            128,
            160,
            192,
            224,
            256,
            320,
          ]
        : const [
            0,
            8,
            16,
            24,
            32,
            40,
            48,
            56,
            64,
            80,
            96,
            112,
            128,
            144,
            160,
          ])[bitrate];
    final size =
        (version == 3 ? 144000 : 72000) * kbps ~/ rate + ((bytes[2] >> 1) & 1);
    if (size < 24 || size > 2048) throw _formatError;
    return _Mp3Frame(version, rate, size);
  }
}

({int size, String? tag, bool ranges}) _envelope(
  FixtureRangeResponse response,
  int offset,
) {
  String? single(String name) {
    final values = response.headers[name];
    if (values == null) return null;
    if (values.length != 1) throw _rangeError;
    return values.single;
  }

  final encoding = single('content-encoding');
  final type = single('content-type')?.split(';').first.trim().toLowerCase();
  if ((encoding != null && encoding != 'identity') ||
      single('transfer-encoding') != null ||
      (type != null &&
          !const {
            'audio/mpeg',
            'audio/mp3',
            'audio/flac',
            'audio/x-flac',
            'audio/wav',
            'audio/wave',
            'audio/x-wav',
            'application/octet-stream',
            'binary/octet-stream',
          }.contains(type))) {
    throw _formatError;
  }
  final length = int.tryParse(single('content-length') ?? '');
  if (length == null || length < 1 || length > _maximumMediaBytes) {
    throw _rangeError;
  }
  int size;
  if (response.status == 206) {
    final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(single('content-range') ?? '');
    if (range == null ||
        int.tryParse(range[1]!) != offset ||
        int.tryParse(range[2]!) != offset + length - 1 ||
        int.tryParse(range[3]!) != offset + length) {
      throw _rangeError;
    }
    size = offset + length;
  } else if (response.status == 200 &&
      offset == 0 &&
      single('content-range') == null) {
    size = length;
  } else {
    throw _rangeError;
  }
  if (size > _maximumMediaBytes) throw _rangeError;
  final etag = single('etag');
  final tag =
      etag != null && RegExp(r'^"[\x21\x23-\x7e]{1,126}"$').hasMatch(etag)
      ? etag
      : null;
  return (
    size: size,
    tag: tag,
    ranges: response.status == 206 || single('accept-ranges') == 'bytes',
  );
}

final class _EncodedAudio implements ControlledEncodedInput {
  _EncodedAudio(
    this._transport,
    this.format,
    this._remoteSize,
    this._dataOffset,
    this._header,
    this._tag,
    this.seekable,
    this._initial,
  );
  final FixtureRangeTransport _transport;
  @override
  final ControlledAudioFormat format;
  final int _remoteSize, _dataOffset;
  final Uint8List _header;
  final String? _tag;
  @override
  final bool seekable;
  final _closing = PcmCancellation();
  final _readers = <_AudioRead>{};
  ControlledPcmRead? _initial;
  @override
  int get size => _remoteSize - _dataOffset + _header.length;

  @override
  Future<ControlledPcmRead> openAt(
    int offset,
    PcmCancellation cancellation,
  ) async {
    _closing.check();
    cancellation.check();
    if (offset < 0 || offset >= size) throw _rangeError;
    final work = PcmCancellation();
    final unlink = _closing.listen(work.cancel);
    final detach = cancellation.listen(work.cancel);
    ControlledPcmRead? reader;
    var attached = false;
    try {
      if (offset == 0 && _initial != null) {
        reader = _initial;
        _initial = null;
      } else {
        _initial?.close();
        _initial = null;
        if (!seekable) throw _rangeError;
        final headerOffset = offset.clamp(0, _header.length);
        final remote =
            _dataOffset + (offset - _header.length).clamp(0, _remoteSize);
        final reply = await work.until(
          _transport.open(remote, _tag, work),
          discard: (late) => late.body.close(),
        );
        reader = reply.body;
        final envelope = _envelope(reply, remote);
        if (envelope.size != _remoteSize ||
            envelope.tag != _tag ||
            reply.status != 206) {
          throw _rangeError;
        }
        if (headerOffset < _header.length) {
          reader = _PrefixRead(
            Uint8List.sublistView(_header, headerOffset),
            reader,
          );
        }
      }
      work.check();
      final result = _AudioRead(reader!, size - offset, work, () {
        unlink();
        detach();
      });
      _readers.add(result);
      result.onClose = () => _readers.remove(result);
      attached = true;
      return result;
    } finally {
      if (!attached) {
        reader?.close();
        unlink();
        detach();
        work.cancel();
      }
    }
  }

  @override
  void close() {
    if (_closing.cancelled) return;
    _closing.cancel();
    _initial?.close();
    _initial = null;
    for (final reader in _readers.toList()) {
      reader.close();
    }
  }
}

final class _AudioRead implements ControlledPcmRead {
  _AudioRead(this._body, this._remaining, this._scope, this._release) {
    _unlisten = _scope.listen(close);
  }
  final ControlledPcmRead _body;
  int _remaining;
  final PcmCancellation _scope;
  final void Function() _release;
  void Function()? _unlisten;
  void Function()? onClose;
  bool _closed = false;
  @override
  Future<Uint8List> read(int maximum) async {
    _scope.check();
    if (_remaining == 0) return Uint8List(0);
    if (_closed || maximum < 1 || maximum > 32 * 1024) throw _rangeError;
    final limit = maximum.clamp(1, _remaining);
    final bytes = await _scope.until(_body.read(limit));
    if (bytes.isEmpty || bytes.length > limit) {
      throw const FixtureMediaException(FixtureMediaFailure.truncated);
    }
    _remaining -= bytes.length;
    if (_remaining == 0) _body.close();
    return bytes;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _unlisten?.call();
    _release();
    onClose?.call();
    _body.close();
    _scope.cancel();
  }
}

final class _Probe {
  _Probe(this.body, this.cancellation);
  final ControlledPcmRead body;
  final PcmCancellation cancellation;
  int offset = 0;
  Future<Uint8List> read(int count) async {
    final result = Uint8List(count);
    var done = 0;
    while (done < count) {
      final limit = (count - done).clamp(1, 32 * 1024);
      final chunk = await cancellation.until(body.read(limit));
      if (chunk.isEmpty || chunk.length > limit) throw _formatError;
      result.setRange(done, done + chunk.length, chunk);
      done += chunk.length;
      offset += chunk.length;
    }
    return result;
  }

  Future<void> skip(int count) async {
    if (count < 0 || count > _maximumMetadata) throw _formatError;
    for (var remaining = count; remaining > 0;) {
      final next = remaining.clamp(1, 32 * 1024);
      await read(next);
      remaining -= next;
    }
  }
}

final class _PrefixRead implements ControlledPcmRead {
  _PrefixRead(this._prefix, this._body);
  Uint8List _prefix;
  final ControlledPcmRead _body;
  bool _closed = false;
  @override
  Future<Uint8List> read(int maximum) async {
    if (_closed) throw const PcmCancelled();
    if (_prefix.isEmpty) return _body.read(maximum);
    final count = maximum.clamp(1, _prefix.length);
    final result = Uint8List.sublistView(_prefix, 0, count);
    _prefix = Uint8List.sublistView(_prefix, count);
    return result;
  }

  @override
  void close() {
    _closed = true;
    _prefix = Uint8List(0);
    _body.close();
  }
}

final class _FirstResponse implements FixtureRangeTransport {
  _FirstResponse(this.transport, this._first);
  final FixtureRangeTransport transport;
  FixtureRangeResponse? _first;
  @override
  Future<FixtureRangeResponse> open(
    int offset,
    String? validator,
    PcmCancellation cancellation,
  ) async {
    final first = _first;
    _first = null;
    return first ?? await transport.open(offset, validator, cancellation);
  }
}

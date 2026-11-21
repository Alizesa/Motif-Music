import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:motif_taglib/motif_taglib.dart';

import '../domain/library_models.dart';
import 'library_metadata_reader.dart';

class TagLibMetadataReader implements LibraryMetadataReader {
  const TagLibMetadataReader({
    this.readDescriptor = _readDescriptor,
    this.closeDescriptor = closeTagLibDescriptor,
  });
  final Future<Map<String, Object?>> Function(int) readDescriptor;
  final void Function(int) closeDescriptor;
  static const _channel = MethodChannel('motif/library_scanner');

  @override
  Future<TrackMetadata> read(LocalAudioFile file) async {
    switch (file.location.platform) {
      case LibraryPlatform.windows:
        final uri = Uri.parse(file.location.locator);
        if (uri.scheme != 'file') throw const FormatException('无效的本地地址');
        final path = File.fromUri(uri).path;
        return Isolate.run(() => _readWindows(file, path));
      case LibraryPlatform.android:
        final uri = Uri.parse(file.location.locator);
        if (uri.scheme != 'content' || uri.host.isEmpty) {
          throw const FormatException('无效的 SAF 地址');
        }
        // Resolve the native asset before acquiring a detached descriptor.
        closeDescriptor(-1);
        final opened = await _channel.invokeMapMethod<String, Object?>(
          'openMetadataFile',
          {'uri': file.location.locator},
        );
        final descriptor = opened?['fd'] as int?;
        if (descriptor == null || descriptor < 0) {
          throw const FormatException('无法打开只读音频描述符');
        }
        // Kotlin detaches ownership to Dart. Native parsing borrows this FD,
        // uses its own duplicate and closes it before the isolate returns.
        try {
          final before = _state(opened!);
          before.verifyExpected(file);
          final tags = await readDescriptor(descriptor);
          final after = await _channel.invokeMapMethod<String, Object?>(
            'metadataFileState',
            {'uri': file.location.locator},
          );
          before.verifyStable(_state(after ?? const {}));
          return metadataFromTagLib(tags);
        } finally {
          closeDescriptor(descriptor);
        }
    }
  }

  static MetadataFileState _state(Map<String, Object?> map) =>
      MetadataFileState(
        sizeBytes: map['sizeBytes'] as int?,
        modifiedMs: map['modifiedMs'] as int?,
      );
}

Future<Map<String, Object?>> _readDescriptor(int descriptor) =>
    Isolate.run(() => readTagLib(descriptor: descriptor));

Future<TrackMetadata> _readWindows(LocalAudioFile file, String path) async {
  final source = File(path);
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file) {
    throw const FileSystemException('音频不可访问');
  }
  final state = MetadataFileState(
    sizeBytes: before.size,
    modifiedMs: before.modified.millisecondsSinceEpoch,
  );
  state.verifyExpected(file);
  final tags = readTagLib(path: path);
  final after = await source.stat();
  if (after.type != FileSystemEntityType.file) {
    throw const FileSystemException('音频已移除');
  }
  state.verifyStable(
    MetadataFileState(
      sizeBytes: after.size,
      modifiedMs: after.modified.millisecondsSinceEpoch,
    ),
  );
  return metadataFromTagLib(tags);
}

TrackMetadata metadataFromTagLib(Map<String, Object?> value) {
  return TrackMetadata(
    title: value['title'] as String? ?? '',
    artist: value['artist'] as String? ?? '',
    album: value['album'] as String? ?? '',
    durationMs: _positiveInt(value['durationMs']),
    bitrateKbps: _positiveInt(value['bitrateKbps']),
    sampleRateHz: _positiveInt(value['sampleRateHz']),
    channels: _positiveInt(value['channels']),
  );
}

int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;

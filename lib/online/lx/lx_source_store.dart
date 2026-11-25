import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/playback_source.dart';
import 'lx_native_worker.dart';
import 'lx_network.dart';

const lxSourceCountLimit = 12;
const lxHostCountLimit = 8;
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _idPattern = RegExp(r'^lx-[0-9a-f]{32}$');
const _metadataLimits = {
  'name': 24,
  'description': 36,
  'version': 36,
  'author': 56,
  'homepage': 1024,
};

final class LxScriptDocument {
  LxScriptDocument._(this.bytes, this.digest, this.info);

  final Uint8List bytes;
  final String digest;
  final Map<String, String> info;

  factory LxScriptDocument.parse(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > lxScriptLimit) {
      throw const FormatException('LX script size');
    }
    final script = utf8.decode(bytes);
    final end = script.indexOf('*/');
    if (!script.startsWith('/*') || end < 2 || end > 8192) {
      throw const FormatException('LX script header');
    }
    final info = <String, String>{
      for (final key in _metadataLimits.keys) key: '',
    };
    for (final line in script.substring(0, end).split('\n')) {
      final match = RegExp(r'^\s*\*\s*@(\w+)[ \t]+(.*)$')
          .firstMatch(line.trimRight());
      if (match == null) continue;
      final key = match[1]!;
      final limit = _metadataLimits[key];
      if (limit == null) continue;
      final value = match[2]!.trim();
      final chars = value.runes.take(limit).toList();
      info[key] =
          String.fromCharCodes(chars) + (value.runes.length > limit ? '…' : '');
    }
    if (info['name']!.isEmpty) info['name'] = '自定义音源';
    return LxScriptDocument._(
      Uint8List.fromList(bytes),
      sha256.convert(bytes).toString(),
      Map.unmodifiable(info),
    );
  }
}

final class LxSourceGrant {
  LxSourceGrant({
    Iterable<String> api = const [],
    Iterable<String> media = const [],
  }) : api = _hosts(api),
       media = _hosts(media);

  final Set<String> api;
  final Set<String> media;

  static Set<String> _hosts(Iterable<String> input) {
    final hosts = <String>{};
    for (final value in input) {
      final host = lxHost(value);
      if (host == null) throw const FormatException('LX hostname');
      hosts.add(host);
      if (hosts.length > lxHostCountLimit) {
        throw const FormatException('LX host count');
      }
    }
    return Set.unmodifiable(hosts);
  }
}

final class LxStoredSource {
  LxStoredSource({
    required this.id,
    required this.digest,
    required this.info,
    required this.version,
    required this.enabled,
    required this.grant,
    Iterable<OnlineQuality> qualities = const [],
  }) : qualities = Set.unmodifiable(qualities);

  factory LxStoredSource.newScript(
    LxScriptDocument document, [
    LxStoredSource? previous,
  ]) {
    final random = Random.secure();
    final id =
        previous?.id ??
        'lx-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    return LxStoredSource(
      id: id,
      digest: document.digest,
      info: document.info,
      version: (previous?.version ?? 0) + 1,
      enabled: false,
      grant: LxSourceGrant(),
    );
  }

  final String id;
  final String digest;
  final Map<String, String> info;
  final int version;
  final bool enabled;
  final LxSourceGrant grant;
  final Set<OnlineQuality> qualities;

  String get name {
    final label = info['name']!
        .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), '')
        .trim();
    return label.isEmpty ? '自定义音源' : label;
  }

  LxStoredSource configure({
    required bool enabled,
    required LxSourceGrant grant,
    required Iterable<OnlineQuality> qualities,
  }) => LxStoredSource(
    id: id,
    digest: digest,
    info: info,
    version: version + 1,
    enabled: enabled,
    grant: grant,
    qualities: qualities,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'digest': digest,
    'version': version,
    'enabled': enabled,
    'api': grant.api.toList(),
    'media': grant.media.toList(),
    'qualities': qualities.map((quality) => quality.lxValue).toList(),
  };
}

/// The manifest holds grants, where each entry references an immutable blob
/// verified against its digest before the worker receives any script bytes.
final class LxSourceStore {
  LxSourceStore(this.directory);
  final Future<Directory> Function() directory;

  File _member(Directory root, String name) =>
      File('${root.path}${Platform.pathSeparator}$name');

  Future<List<LxStoredSource>> load() async {
    final root = await directory();
    final manifest = _member(root, 'sources.json');
    if (!await manifest.exists()) return const [];
    final value = jsonDecode(
      utf8.decode(await _boundedRead(manifest, 64 * 1024)),
    );
    if (value is! Map || value['schema'] != 1) {
      throw const FormatException('LX catalog');
    }
    final entries = value['sources'];
    if (entries is! List || entries.length > lxSourceCountLimit) {
      throw const FormatException('LX catalog count');
    }
    final sources = <LxStoredSource>[];
    final seen = <String>{};
    for (final entry in entries) {
      if (entry is! Map ||
          entry['id'] is! String ||
          !_idPattern.hasMatch(entry['id'] as String) ||
          entry['digest'] is! String ||
          !_digestPattern.hasMatch(entry['digest'] as String) ||
          entry['version'] is! int ||
          (entry['version'] as int) < 1 ||
          !seen.add(entry['id'] as String)) {
        continue;
      }
      try {
        final digest = entry['digest'] as String;
        final script = await _readDocument(root, digest);
        final grant = LxSourceGrant(
          api: (entry['api'] as List).cast<String>(),
          media: (entry['media'] as List).cast<String>(),
        );
        final declared = entry['qualities'] as List;
        final qualities = OnlineQuality.values
            .where((q) => declared.contains(q.lxValue))
            .toSet();
        sources.add(
          LxStoredSource(
            id: entry['id'] as String,
            digest: digest,
            info: script.info,
            version: entry['version'] as int,
            enabled: entry['enabled'] == true && qualities.isNotEmpty,
            grant: grant,
            qualities: qualities,
          ),
        );
      } catch (_) {
        // A lost or modified script cannot inherit the persisted grant.
      }
    }
    return List.unmodifiable(sources);
  }

  Future<LxScriptDocument> read(LxStoredSource source) async =>
      _readDocument(await directory(), source.digest);

  Future<LxScriptDocument> _readDocument(Directory root, String digest) async {
    if (!_digestPattern.hasMatch(digest)) {
      throw const FormatException('LX digest');
    }
    final document = LxScriptDocument.parse(
      await _boundedRead(_member(root, '$digest.js'), lxScriptLimit),
    );
    if (document.digest != digest) {
      throw const FormatException('Changed LX script');
    }
    return document;
  }

  Future<void> import(LxScriptDocument document) async {
    final root = await directory();
    await root.create(recursive: true);
    await _replace(_member(root, '${document.digest}.js'), document.bytes);
  }

  Future<void> save(List<LxStoredSource> sources) async {
    final root = await directory();
    await root.create(recursive: true);
    await _replace(
      _member(root, 'sources.json'),
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'sources': sources.map((source) => source.toJson()).toList(),
        }),
      ),
    );
  }

  Future<void> discardBlob(String digest) async {
    if (!_digestPattern.hasMatch(digest)) return;
    final file = _member(await directory(), '$digest.js');
    if (await file.exists()) await file.delete();
  }

  Future<void> _replace(File target, List<int> bytes) async {
    final temporary = File(
      '${target.path}.${Random.secure().nextInt(0x7fffffff)}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

/// Enforce the size while streaming, even when a picker/provider omits it.
Future<Uint8List> readLxScript(Stream<List<int>> input) async {
  final bytes = BytesBuilder(copy: false);
  await for (final part in input) {
    if (bytes.length + part.length > lxScriptLimit) {
      throw const FormatException('LX script exceeds size limit');
    }
    bytes.add(part);
  }
  return bytes.takeBytes();
}

Future<Uint8List> _boundedRead(File file, int maximum) async {
  final input = await file.open();
  try {
    final bytes = await input.read(maximum + 1);
    if (bytes.isEmpty || bytes.length > maximum) {
      throw const FormatException('LX file size');
    }
    return bytes;
  } finally {
    await input.close();
  }
}

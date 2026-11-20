import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'source_archive.dart';

const sources = [
  (
    name: 'taglib-2.3',
    url: 'https://codeload.github.com/taglib/taglib/zip/refs/tags/v2.3',
    digest: 'da5e92d9f9850480a1113827b869bd386dc6c28a1b132ee97aab19edbac4ce38',
  ),
  (
    name: 'utfcpp-4.0.9',
    url: 'https://codeload.github.com/nemtrif/utfcpp/zip/refs/tags/v4.0.9',
    digest: '73802895d0cf7b000cdf8e6ee5d69b963a829d4ea419562afd8f190adef87d5f',
  ),
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    // Explicit local test mode; real parsing fails unless a reader is injected.
    // Never enabled in the checked-in application pubspec or CI configuration.
    if (input.userDefines['test-only-injected-reader'] == true) {
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'motif_taglib.dart',
          linkMode: DynamicLoadingSystem(
            Uri.file('motif_taglib_test_requires_injection'),
          ),
        ),
      );
      return;
    }
    final os = input.config.code.targetOS;
    if (os != OS.windows && os != OS.android && os != OS.linux) {
      throw UnsupportedError(
        'Supported targets: Windows/Android and Linux CI tests',
      );
    }
    final sourceDir = Directory.fromUri(
      input.outputDirectory.resolve('verified_sources/'),
    );
    await sourceDir.create(recursive: true);
    for (final source in sources) {
      final archive = File.fromUri(sourceDir.uri.resolve('${source.name}.zip'));
      final bytes = await loadVerifiedSourceArchive(
        cache: archive,
        source: Uri.parse(source.url),
        expectedSha256: source.digest,
      );
      output.dependencies.add(archive.uri);
      for (final entry in ZipDecoder().decodeBytes(bytes)) {
        if (!entry.isFile) continue;
        if (!entry.name.startsWith('${source.name}/') ||
            entry.name.split('/').contains('..') ||
            entry.isSymbolicLink) {
          throw FormatException(
            'Unexpected source archive path: ${entry.name}',
          );
        }
        final file = File.fromUri(sourceDir.uri.resolve(entry.name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content);
      }
    }
    final taglib = Directory.fromUri(
      sourceDir.uri.resolve('taglib-2.3/taglib/'),
    );
    final headers = Directory.fromUri(
      input.outputDirectory.resolve('taglib_headers/'),
    );
    await headers.create(recursive: true);
    final headerNames = <String>{};
    final cpp = <String>[];
    // Flatten includes to keep Windows compiler command lines bounded.
    await for (final entity in taglib.list(recursive: true)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.cpp')) cpp.add(entity.path);
      if (!RegExp(r'\.(h|hpp|tcc|inl|inc)$').hasMatch(entity.path)) continue;
      final name = entity.uri.pathSegments.last;
      if (!headerNames.add(name)) {
        throw StateError('Duplicate TagLib header: $name');
      }
      await entity.copy(File.fromUri(headers.uri.resolve(name)).path);
    }
    cpp.sort();
    final includes = [
      Directory.fromUri(input.packageRoot.resolve('src/')).path,
      headers.path,
      Directory.fromUri(sourceDir.uri.resolve('taglib-2.3/')).path,
      taglib.path,
      Directory.fromUri(sourceDir.uri.resolve('utfcpp-4.0.9/source/')).path,
    ];
    const defines = {'HAVE_CONFIG_H': '1', 'TAGLIB_STATIC': '1'};
    final libraries = <String>[];
    if (os == OS.windows) {
      for (var start = 0; start < cpp.length; start += 4) {
        final name = 'motif_taglib_part_${start ~/ 4}';
        libraries.add(name);
        await CLibrary(
          name: name,
          assetName: null,
          sources: cpp.skip(start).take(4).toList(),
          includes: includes,
          defines: defines,
          language: Language.cpp,
          std: 'c++17',
        ).build(
          input: input,
          output: output,
          linkModePreference: LinkModePreference.static,
        );
      }
    }
    await CLibrary(
      name: 'motif_taglib',
      assetName: 'motif_taglib.dart',
      sources: ['src/motif_taglib.cpp', if (os != OS.windows) ...cpp],
      includes: includes,
      defines: defines,
      language: Language.cpp,
      std: 'c++17',
      cppLinkStdLib: os == OS.android ? 'c++_static' : null,
      flags: [
        if (os != OS.windows) '-fvisibility=hidden',
        if (os == OS.android) '-Wl,-z,max-page-size=16384',
      ],
      libraries: [...libraries, if (os == OS.android || os == OS.linux) 'm'],
      libraryDirectories: [Directory.fromUri(input.outputDirectory).path],
    ).build(
      input: input,
      output: output,
      linkModePreference: LinkModePreference.dynamic,
    );
  });
}

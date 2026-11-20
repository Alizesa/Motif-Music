import 'dart:async';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../domain/audio_file_extensions.dart';
import '../domain/library_models.dart';
import 'library_platform_source.dart';

/// SAF directory selection and native traversal, pulled one bounded batch at a time.
final class AndroidSafLibrarySource implements LibraryPlatformSource {
  static const _methods = MethodChannel('motif/library_scanner');
  static var _scanSequence = 0;

  const AndroidSafLibrarySource();

  @override
  LibraryPlatform get platform => LibraryPlatform.android;

  @override
  Future<PickedLibraryDirectory?> pickDirectory() async {
    final existingGrants = await _methods.invokeListMethod<String>(
      'persistedTrees',
    );
    if (existingGrants == null) {
      throw const LibraryTraversalException(
        'Android could not inspect SAF grants.',
      );
    }
    final uri = await FilePicker.pickDirectory(
      dialogTitle: '选择音乐目录',
      androidOptions: const FilePickerAndroidOptions(
        safOptions: AndroidSAFOptions(
          grant: AndroidSAFGrant.lifetime,
          accessMode: AndroidSAFAccessMode.readOnly,
          persistGrant: true,
          copyToCache: false,
        ),
      ),
    );
    if (uri == null) return null;
    if (uri.scheme != 'content' || uri.host.isEmpty) {
      throw const LibraryTraversalException(
        'Android directory picker did not return a SAF content URI.',
      );
    }

    final Map<String, Object?> details;
    try {
      final response = await _methods.invokeMapMethod<String, Object?>(
        'describeTree',
        {'treeUri': uri.toString()},
      );
      if (response?['key'] is! String ||
          (response!['key'] as String).isEmpty ||
          response['displayName'] is! String ||
          (response['displayName'] as String).isEmpty) {
        throw const LibraryTraversalException(
          'Android returned invalid SAF directory details.',
        );
      }
      details = response;
    } catch (error) {
      // Roll back only a newly acquired grant. Existing roots may use the same URI.
      if (!existingGrants.contains(uri.toString())) {
        try {
          await _methods.invokeMethod<void>('releaseTree', {
            'treeUri': uri.toString(),
          });
        } on PlatformException {
          // Preserve the inspection error if the provider already revoked access.
        }
      }
      if (error is PlatformException) throw _traversalError(error);
      rethrow;
    }
    return PickedLibraryDirectory(
      location: FileLocation(
        platform: platform,
        key: details['key'] as String,
        locator: uri.toString(),
      ),
      displayName: details['displayName'] as String,
    );
  }

  @override
  Stream<List<ObservedAudioFile>> scanBatches(
    FileLocation root, {
    required LibraryScanCancellation cancellation,
  }) async* {
    if (root.platform != platform) {
      throw ArgumentError.value(root.platform, 'root.platform');
    }
    final uri = Uri.tryParse(root.locator);
    if (uri == null || uri.scheme != 'content' || uri.host.isEmpty) {
      throw const LibraryTraversalException(
        'Invalid Android SAF directory URI.',
      );
    }
    cancellation.throwIfCancelled();
    final scanId =
        '${DateTime.now().microsecondsSinceEpoch}-${_scanSequence++}';
    final stopListening = cancellation.onCancel(() {
      unawaited(_cancelScan(scanId));
    });
    var completed = false;
    try {
      await _awaitCall(
        _methods.invokeMethod<void>('startScan', {
          'scanId': scanId,
          'treeUri': root.locator,
          'extensions': audioFileExtensions.toList(growable: false),
        }),
        cancellation,
      );
      while (true) {
        cancellation.throwIfCancelled();
        final response = await _awaitCall(
          _methods.invokeMethod<Object?>('nextBatch', {'scanId': scanId}),
          cancellation,
        );
        cancellation.throwIfCancelled();
        if (response is! Map) {
          throw const LibraryTraversalException(
            'Android scanner returned an invalid response.',
          );
        }
        if (response['type'] == 'complete' && response['files'] == null) {
          completed = true;
          return;
        }
        final rawFiles = response['files'];
        if (response['type'] != 'batch' ||
            rawFiles is! List ||
            rawFiles.isEmpty ||
            rawFiles.length > libraryScanBatchLimit) {
          throw const LibraryTraversalException(
            'Android scanner returned an invalid batch.',
          );
        }
        // Reject the whole batch rather than silently losing malformed rows.
        final files = <ObservedAudioFile>[
          for (final raw in rawFiles) _observedFile(raw),
        ];
        yield List.unmodifiable(files);
        // The next native request happens only after the consumer persists this batch.
      }
    } on PlatformException catch (error) {
      cancellation.throwIfCancelled();
      throw _traversalError(error);
    } finally {
      stopListening();
      if (!completed) await _cancelScan(scanId);
    }
  }

  @override
  Future<void> releaseDirectory(FileLocation root) async {
    if (root.platform != platform) return;
    await _methods.invokeMethod<void>('releaseTree', {'treeUri': root.locator});
  }

  static LibraryTraversalException _traversalError(PlatformException error) =>
      LibraryTraversalException(
        error.message ?? 'Android SAF operation failed (${error.code}).',
        rootAccessRevoked: error.code == 'permission_revoked',
      );

  static Future<void> _cancelScan(String scanId) async {
    try {
      await _methods.invokeMethod<void>('cancelScan', {'scanId': scanId});
    } on PlatformException {
      // The engine may already be shutting down. Preserve the original failure.
    } on MissingPluginException {
      // The native handler has already been detached.
    }
  }

  static Future<T> _awaitCall<T>(
    Future<T> operation,
    LibraryScanCancellation cancellation,
  ) async {
    final result = Completer<T>();
    final stopListening = cancellation.onCancel(() {
      if (!result.isCompleted) {
        result.completeError(const LibraryScanCancelledException());
      }
    });
    unawaited(
      operation.then<void>(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    try {
      return await result.future;
    } finally {
      stopListening();
    }
  }

  static ObservedAudioFile _observedFile(Object? raw) {
    if (raw is! Map) {
      throw const LibraryTraversalException(
        'Android returned an invalid file.',
      );
    }
    final key = raw['key'];
    final locator = raw['locator'];
    final fileName = raw['fileName'];
    final size = raw['sizeBytes'];
    final modified = raw['modifiedMs'];
    final uri = locator is String ? Uri.tryParse(locator) : null;
    if (key is! String ||
        key.isEmpty ||
        locator is! String ||
        uri?.scheme != 'content' ||
        uri!.host.isEmpty ||
        fileName is! String ||
        !isSupportedAudioFileName(fileName) ||
        (size != null && (size is! int || size < 0)) ||
        (modified != null && (modified is! int || modified < 0))) {
      throw const LibraryTraversalException(
        'Android scanner returned an invalid file location or stat.',
      );
    }
    return ObservedAudioFile(
      location: FileLocation(
        platform: LibraryPlatform.android,
        key: key,
        locator: locator,
      ),
      fileName: fileName,
      sizeBytes: size as int?,
      modifiedMs: modified as int?,
    );
  }
}

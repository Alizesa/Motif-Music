import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'library_database.dart';

/// SQL and isolate creation are deferred until the first database operation.
/// Keep one instance for the application lifetime and close it at shutdown.
LibraryDatabase openLibraryDatabase() => LibraryDatabase(
  LazyDatabase(
    () => driftDatabase(
      name: 'motif_library',
      native: DriftNativeOptions(databaseDirectory: _supportDirectory),
    ),
  ),
);

Future<Directory> _supportDirectory() async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return directory;
}

import 'package:drift/drift.dart';

part 'library_database.g.dart';

/// One long-lived instance per application, with a background executor on device.
@DriftDatabase(include: {'library_schema.drift'})
class LibraryDatabase extends _$LibraryDatabase {
  LibraryDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    // Introduce explicit, non-destructive migrations before incrementing v1.
    onUpgrade: (migrator, from, to) async {
      throw StateError('Missing library migration from $from to $to');
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 3000');
      await customStatement('PRAGMA journal_mode = WAL');
      // Page cache target is 4 MiB, not a guarantee on total process memory.
      await customStatement('PRAGMA cache_size = -4096');
      await customStatement('PRAGMA temp_store = FILE');
      await customStatement('PRAGMA wal_autocheckpoint = 1000');
      // SQLite can exceed this between checkpoints; this is not a hard WAL cap.
      await customStatement('PRAGMA journal_size_limit = 8388608');
    },
  );
}

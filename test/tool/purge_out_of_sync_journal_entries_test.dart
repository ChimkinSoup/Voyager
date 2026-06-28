import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/dev/out_of_sync_journal_entry_purge.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

/// Hard-deletes out-of-sync journal rows from the local SQLite database.
///
/// Close Voyager before running so voyager.sqlite is not locked:
///   flutter test test/tool/purge_out_of_sync_journal_entries_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('purge out-of-sync journal entries locally', () async {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    expect(home, isNotNull, reason: 'Could not resolve home directory');

    final dbPath = p.join(home!, 'Documents', 'voyager.sqlite');
    expect(
      File(dbPath).existsSync(),
      isTrue,
      reason: 'Database not found at $dbPath',
    );

    final db = AppDatabase(NativeDatabase(File(dbPath)));
    addTearDown(db.close);

    final repo = DriftJournalRepository(db);
    for (final target in OutOfSyncJournalEntryPurge.targets) {
      final existing = await repo.getEntry(target.id);
      if (existing != null) {
        await repo.hardDeleteEntry(target.id);
      }
      // ignore: avoid_print
      print(
        '${target.title} (${target.id}): localDeleted=${existing != null}',
      );
    }
  });
}

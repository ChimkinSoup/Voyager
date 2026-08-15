// Schema 65 splits "was the all-view open?" out of the last-viewed id columns.
// The journal page used to record the all-journals view by overwriting
// last_viewed_journal_id with the sentinel 'ALL_JOURNALS', so existing
// databases carry rows that need converting.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

/// Rewinds a schema-65 database to look like a schema-64 one: drops the two
/// new columns and resets user_version, so reopening it runs the real
/// onUpgrade path rather than a hand-written approximation of it.
Future<void> _rewindToSchema64(File file) async {
  final raw = NativeDatabase(file);
  final db = AppDatabase(raw);
  await db.customStatement(
    'ALTER TABLE settings_table DROP COLUMN journal_show_all_entries',
  );
  await db.customStatement(
    'ALTER TABLE settings_table DROP COLUMN todo_show_all_tasks',
  );
  await db.customStatement('PRAGMA user_version = 64');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('64→65 converts the ALL_JOURNALS sentinel into the new flag', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final seedRepo = DriftSettingsRepository(seed);
    await seedRepo.saveSettings(
      (await seedRepo.getSettings()).copyWith(
        lastViewedJournalId: 'ALL_JOURNALS',
        lastViewedTodoListId: 'work',
      ),
    );
    await seed.close();
    await _rewindToSchema64(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final settings = await DriftSettingsRepository(upgraded).getSettings();

    expect(settings.journalShowAllEntries, isTrue);
    // Unrecoverable for these rows — the sentinel overwrote it — so it goes
    // null and the page falls back to the default journal exactly once.
    expect(settings.lastViewedJournalId, isNull);
    // The todo side never used a sentinel, so its id survives untouched and
    // its flag simply starts off.
    expect(settings.lastViewedTodoListId, 'work');
    expect(settings.todoShowAllTasks, isFalse);
  });

  test('64→65 leaves a real journal id alone', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final seedRepo = DriftSettingsRepository(seed);
    await seedRepo.saveSettings(
      (await seedRepo.getSettings()).copyWith(lastViewedJournalId: 'dreams'),
    );
    await seed.close();
    await _rewindToSchema64(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final settings = await DriftSettingsRepository(upgraded).getSettings();

    expect(settings.lastViewedJournalId, 'dreams');
    expect(settings.journalShowAllEntries, isFalse);
  });

  test('both flags round-trip through the settings repository', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftSettingsRepository(db);

    await repo.saveSettings(
      (await repo.getSettings()).copyWith(
        journalShowAllEntries: true,
        todoShowAllTasks: true,
        lastViewedJournalId: 'dreams',
        lastViewedTodoListId: 'work',
      ),
    );

    final settings = await repo.getSettings();
    // The point of the split: the all-view and the concrete id are both
    // readable at once.
    expect(settings.journalShowAllEntries, isTrue);
    expect(settings.todoShowAllTasks, isTrue);
    expect(settings.lastViewedJournalId, 'dreams');
    expect(settings.lastViewedTodoListId, 'work');
  });
}

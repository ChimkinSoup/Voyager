// Schema 122 adds the cheat sheet's three tables and the two device-local
// settings columns; 123 adds an entry's label. An existing database has to
// gain all of them without losing what was already in it.
//
// The database is rewound to look like a schema-121 one and reopened, so the
// real `onUpgrade` path runs rather than a hand-written approximation of it —
// the same shape `secondary_collections_migration_test.dart` uses.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

/// Everything schema 122 adds.
const _addedTables = [
  'leet_code_cheat_tabs_table',
  'leet_code_cheat_sections_table',
  'leet_code_cheat_entries_table',
];

const _addedSettingsColumns = [
  'leet_code_cheat_last_tab_id',
  'leet_code_cheat_collapsed_sections_json',
];

/// Rewinds a current database to look like a schema-122 one — which is to
/// say, before the entry label column.
Future<void> _rewindToSchema122(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE leet_code_cheat_entries_table DROP COLUMN label',
  );
  await db.customStatement('PRAGMA user_version = 122');
  await db.close();
}

/// Rewinds a database to look like a schema-121 one.
Future<void> _rewindToSchema121(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  for (final table in _addedTables) {
    await db.customStatement('DROP TABLE IF EXISTS $table');
  }
  for (final column in _addedSettingsColumns) {
    await db.customStatement('ALTER TABLE settings_table DROP COLUMN $column');
  }
  await db.customStatement('PRAGMA user_version = 121');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_cheat_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final now = DateTime.utc(2026, 9, 20, 12);

  test(
    '121→122 adds the three tables and keeps what was already there',
    () async {
      final seed = AppDatabase(NativeDatabase(file));
      await DriftLeetCodeRepository(seed).upsertProblem(
        LeetCodeProblem(
          id: 'lc-1',
          createdAt: now,
          updatedAt: now,
          title: 'Two Sum',
          questionFrontendId: '1',
          difficulty: LeetCodeDifficulty.easy,
          tags: const ['hash-table'],
          solutions: const [LeetCodeSolution(algorithm: 'Hash map')],
          solvedAt: now,
        ),
      );
      await seed.close();

      await _rewindToSchema121(file);

      // Reopening runs the real onUpgrade.
      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final repo = DriftLeetCodeRepository(upgraded);

      // The problem that predates the migration is untouched.
      expect((await repo.listProblems()).single.title, 'Two Sum');

      // And all three new tables are usable.
      await repo.upsertCheatTab(
        LeetCodeCheatTab(
          id: 'tab-1',
          name: 'Java',
          languageKey: 'java',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertCheatSection(
        LeetCodeCheatSection(
          id: 'section-1',
          tabId: 'tab-1',
          name: 'ArrayList',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertCheatEntry(
        LeetCodeCheatEntry(
          id: 'entry-1',
          sectionId: 'section-1',
          command: '.add(e)',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(await repo.listCheatTabs(), hasLength(1));
      expect(await repo.listCheatSections(), hasLength(1));
      expect(await repo.listCheatEntries(), hasLength(1));
    },
  );

  test(
    '121→122 adds the device-local settings columns at their defaults',
    () async {
      final seed = AppDatabase(NativeDatabase(file));
      await DriftSettingsRepository(seed).getSettings();
      await seed.close();

      await _rewindToSchema121(file);

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final settings = await DriftSettingsRepository(upgraded).getSettings();

      // No backfill: an existing row reads as "no tab remembered" and "nothing
      // collapsed", which is exactly right for a device-local preference.
      expect(settings.leetCodeCheatLastTabId, isNull);
      expect(settings.leetCodeCheatCollapsedSections, isEmpty);
    },
  );

  test(
    '122→123 adds the entry label column and keeps the rows it finds',
    () async {
      final seed = AppDatabase(NativeDatabase(file));
      final seedRepo = DriftLeetCodeRepository(seed);
      await seedRepo.upsertCheatTab(
        LeetCodeCheatTab(
          id: 'tab-1',
          name: 'Java',
          languageKey: 'java',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await seedRepo.upsertCheatSection(
        LeetCodeCheatSection(
          id: 'section-1',
          tabId: 'tab-1',
          name: 'ArrayList',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await seedRepo.upsertCheatEntry(
        LeetCodeCheatEntry(
          id: 'entry-1',
          sectionId: 'section-1',
          command: '.add(e)',
          description: 'Appends to the back.',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await seed.close();

      await _rewindToSchema122(file);

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final repo = DriftLeetCodeRepository(upgraded);

      // The row that predates the column keeps everything else and reads as
      // "no label", which is what collapses its label column.
      final entry = (await repo.listCheatEntries()).single;
      expect(entry.command, '.add(e)');
      expect(entry.description, 'Appends to the back.');
      expect(entry.label, isNull);

      // And the column is writable.
      await repo.upsertCheatEntry(entry.copyWith(label: 'Append'));
      expect((await repo.listCheatEntries()).single.label, 'Append');
    },
  );

  test(
    'a database older than 122 gets the label column with the table',
    () async {
      final seed = AppDatabase(NativeDatabase(file));
      await seed.close();

      // The rewind drops the tables entirely, so the upgrade builds them at
      // today's shape — the label ADD COLUMN has to stay out of its way.
      await _rewindToSchema121(file);

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final repo = DriftLeetCodeRepository(upgraded);

      await repo.upsertCheatTab(
        LeetCodeCheatTab(
          id: 'tab-1',
          name: 'Java',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertCheatSection(
        LeetCodeCheatSection(
          id: 'section-1',
          tabId: 'tab-1',
          name: 'ArrayList',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertCheatEntry(
        LeetCodeCheatEntry(
          id: 'entry-1',
          sectionId: 'section-1',
          command: '.add(e)',
          label: 'Append',
          position: kCheatPositionStep,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect((await repo.listCheatEntries()).single.label, 'Append');
    },
  );

  test(
    'the indexes the read queries lean on exist after the upgrade',
    () async {
      final seed = AppDatabase(NativeDatabase(file));
      await seed.close();
      await _rewindToSchema121(file);

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);

      // Declared via @TableIndex, so createAll() covers a fresh database — an
      // upgraded one needs the migration's own CREATE INDEX to have run.
      final rows = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name LIKE 'idx_leetcode_cheat%'",
          )
          .get();
      expect(
        rows.map((r) => r.data['name']),
        unorderedEquals([
          'idx_leetcode_cheat_sections_tab',
          'idx_leetcode_cheat_entries_section',
        ]),
      );
    },
  );
}

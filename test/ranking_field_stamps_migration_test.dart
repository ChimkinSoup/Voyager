// Schema 110 adds per-field merge stamps to ranking entries and units. An
// existing database has rows written without the column, and the upgrade has
// to leave them readable as unstamped — which the merge reads as "every field
// last changed at updatedAt" — not as a decode failure.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';

/// Rewinds a schema-110 database to look like a schema-109 one, so reopening
/// runs the real onUpgrade.
Future<void> _rewindToSchema109(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE ranking_parents_table DROP COLUMN field_updated_at_json',
  );
  await db.customStatement(
    'ALTER TABLE ranking_children_table DROP COLUMN field_updated_at_json',
  );
  await db.customStatement('PRAGMA user_version = 109');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_field_stamps_migration');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'rows written before the column read as unstamped, and stamp after',
    () async {
      final now = DateTime.utc(2026, 8, 1);
      final seedDb = AppDatabase(NativeDatabase(file));
      final seedRepo = DriftRankingRepository(seedDb);
      final category = RankingCategory(
        id: newId(),
        name: 'Shows',
        colorValue: 0xFF7C9EFF,
        createdAt: now,
        updatedAt: now,
      );
      await seedRepo.upsertCategory(category);
      final parent = RankingParent(
        id: newId(),
        categoryId: category.id,
        title: 'Severance',
        notes: 'slow burn',
        createdAt: now,
        updatedAt: now,
      );
      await seedRepo.upsertParent(parent);
      final child = RankingChild(
        id: newId(),
        parentId: parent.id,
        name: 'Pilot',
        createdAt: now,
        updatedAt: now,
      );
      await seedRepo.upsertChild(child);
      await seedDb.close();
      await _rewindToSchema109(file);

      final upgraded = AppDatabase(NativeDatabase(file));
      final repo = DriftRankingRepository(upgraded);
      final readParent = (await repo.getParent(parent.id))!;
      expect(readParent.fieldUpdatedAt, isEmpty);
      expect(readParent.notes, 'slow burn');
      expect((await repo.getChild(child.id))!.fieldUpdatedAt, isEmpty);

      await repo.upsertParent(readParent.copyWith(title: 'Severance S2'));
      await upgraded.close();

      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      final stamped = (await DriftRankingRepository(
        reopened,
      ).getParent(parent.id))!;
      expect(stamped.fieldUpdatedAt['title']!.isAfter(now), isTrue);
      // Untouched fields are pinned to the row's old updatedAt, not to the edit.
      expect(stamped.fieldUpdatedAt['notes'], now);
    },
  );
}

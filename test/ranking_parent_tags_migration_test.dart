// Schema 101 adds structured tags to a ranking parent. An existing database
// has rows written without the column, and the upgrade has to leave every one
// of them readable — as untagged, not as a decode failure.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';

/// Rewinds a schema-101 database to look like a schema-100 one: drops the
/// column the upgrade adds and resets user_version, so reopening runs the real
/// onUpgrade rather than a hand-written approximation of it.
Future<void> _rewindToSchema100(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE ranking_parents_table DROP COLUMN tags_json',
  );
  await db.customStatement('PRAGMA user_version = 100');
  await db.close();
}

Future<RankingParent> _seed(File file) async {
  final now = utcNow();
  final db = AppDatabase(NativeDatabase(file));
  final repository = DriftRankingRepository(db);
  final category = RankingCategory(
    id: newId(),
    name: 'Shows',
    colorValue: 0xFF7C9EFF,
    createdAt: now,
    updatedAt: now,
  );
  await repository.upsertCategory(category);
  final parent = RankingParent(
    id: newId(),
    categoryId: category.id,
    title: 'Severance',
    overallScore: 9,
    notes: 'slow burn #scifi',
    createdAt: now,
    updatedAt: now,
  );
  await repository.upsertParent(parent);
  await db.close();
  return parent;
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_parent_tags_migration');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('an entry written before the column reads as untagged', () async {
    final seeded = await _seed(file);
    await _rewindToSchema100(file);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final parent = (await DriftRankingRepository(
      db,
    ).listParents(seeded.categoryId)).single;

    expect(parent.id, seeded.id);
    expect(parent.tags, isEmpty);
    // The upgrade adds a column and touches nothing else on the row. The note
    // tag in particular stays exactly where it was written: §4.3 keeps the two
    // systems apart, so nothing is promoted out of the notes.
    expect(parent.title, 'Severance');
    expect(parent.overallScore, 9);
    expect(parent.notes, 'slow burn #scifi');
  });

  test('tags written after the upgrade survive a reopen', () async {
    final seeded = await _seed(file);
    await _rewindToSchema100(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final repository = DriftRankingRepository(upgraded);
    final parent = (await repository.listParents(seeded.categoryId)).single;
    await repository.upsertParent(parent.copyWith(tags: ['scifi', 'slow']));
    await upgraded.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      (await DriftRankingRepository(
        db,
      ).listParents(seeded.categoryId)).single.tags,
      ['scifi', 'slow'],
    );
  });
}

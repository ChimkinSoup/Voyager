// Schema 100 retires the two half-step booleans a ranking category carried in
// favour of a three-way precision, because a boolean has no way to say
// "tenths". Existing databases hold rows written under the old meaning, and
// the upgrade has to carry that meaning across: half stars on became `half`,
// half stars off became `integers`.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';

/// Rewinds a schema-100 database to look like a schema-99 one: puts the two
/// booleans back, drops the columns the upgrade adds, and resets
/// user_version — so reopening runs the real onUpgrade rather than a
/// hand-written approximation of it.
Future<void> _rewindToSchema99(
  File file, {
  required bool parentHalfSteps,
  required bool childHalfSteps,
}) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE ranking_categories_table '
    'ADD COLUMN parent_half_steps_enabled INTEGER NOT NULL DEFAULT 1',
  );
  await db.customStatement(
    'ALTER TABLE ranking_categories_table '
    'ADD COLUMN child_half_steps_enabled INTEGER NOT NULL DEFAULT 1',
  );
  await db.customStatement(
    'UPDATE ranking_categories_table SET '
    'parent_half_steps_enabled = ${parentHalfSteps ? 1 : 0}, '
    'child_half_steps_enabled = ${childHalfSteps ? 1 : 0}',
  );
  await db.customStatement(
    'ALTER TABLE ranking_categories_table DROP COLUMN parent_score_precision',
  );
  await db.customStatement(
    'ALTER TABLE ranking_categories_table DROP COLUMN child_score_precision',
  );
  await db.customStatement('PRAGMA user_version = 99');
  await db.close();
}

Future<RankingCategory> _seed(File file) async {
  final now = utcNow();
  final db = AppDatabase(NativeDatabase(file));
  final category = RankingCategory(
    id: newId(),
    name: 'Shows',
    colorValue: 0xFF7C9EFF,
    parentScoreMax: 10,
    createdAt: now,
    updatedAt: now,
  );
  await DriftRankingRepository(db).upsertCategory(category);
  await db.close();
  return category;
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_precision_migration');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('half steps on becomes half precision', () async {
    final seeded = await _seed(file);
    await _rewindToSchema99(file, parentHalfSteps: true, childHalfSteps: true);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final category = (await DriftRankingRepository(db).listCategories()).single;

    expect(category.id, seeded.id);
    expect(category.parentScorePrecision, RankingScorePrecision.half);
    expect(category.childScorePrecision, RankingScorePrecision.half);
    // Everything else the row held is untouched by the fold.
    expect(category.name, 'Shows');
    expect(category.parentScoreMax, 10);
  });

  test('half steps off becomes integer precision, per surface', () async {
    await _seed(file);
    await _rewindToSchema99(file, parentHalfSteps: false, childHalfSteps: true);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final category = (await DriftRankingRepository(db).listCategories()).single;

    // The two settings were independent before the change and stay so after
    // it: an entry on whole stars does not drag its units onto them.
    expect(category.parentScorePrecision, RankingScorePrecision.integers);
    expect(category.childScorePrecision, RankingScorePrecision.half);
  });

  test('the retired columns are gone afterwards', () async {
    await _seed(file);
    await _rewindToSchema99(
      file,
      parentHalfSteps: false,
      childHalfSteps: false,
    );

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    // Force the upgrade to run before the schema is read.
    await DriftRankingRepository(db).listCategories();

    final columns = await db
        .customSelect(
          "SELECT name FROM pragma_table_info('ranking_categories_table')",
        )
        .get();
    final names = [for (final row in columns) row.read<String>('name')];
    expect(names, contains('parent_score_precision'));
    expect(names, contains('child_score_precision'));
    expect(names, isNot(contains('parent_half_steps_enabled')));
    expect(names, isNot(contains('child_half_steps_enabled')));
  });
}

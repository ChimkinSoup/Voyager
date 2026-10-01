// Schema 132 adds locations to a ranking parent and the location toggle to a
// category. An existing database has rows written without either column, and
// the upgrade has to leave every one of them readable — with no locations and
// the toggle off, not as a decode failure.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';

/// Rewinds a schema-132 database to look like a schema-131 one: drops the
/// columns the upgrade adds and resets user_version, so reopening runs the
/// real onUpgrade rather than a hand-written approximation of it.
Future<void> _rewindToSchema131(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE ranking_parents_table DROP COLUMN locations_json',
  );
  await db.customStatement(
    'ALTER TABLE ranking_categories_table DROP COLUMN location_enabled',
  );
  await db.customStatement('PRAGMA user_version = 131');
  await db.close();
}

Future<RankingParent> _seed(File file) async {
  final now = utcNow();
  final db = AppDatabase(NativeDatabase(file));
  final repository = DriftRankingRepository(db);
  final category = RankingCategory(
    id: newId(),
    name: 'Restaurants',
    colorValue: 0xFF7C9EFF,
    createdAt: now,
    updatedAt: now,
  );
  await repository.upsertCategory(category);
  final parent = RankingParent(
    id: newId(),
    categoryId: category.id,
    title: 'Lazeez',
    overallScore: 4,
    tags: const ['shawarma'],
    createdAt: now,
    updatedAt: now,
  );
  await repository.upsertParent(parent);
  await db.close();
  return parent;
}

/// Rewinds to schema 132: the map settings columns 133 adds are gone.
Future<void> _rewindToSchema132(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  for (final column in [
    'rankings_map_view_categories_json',
    'rankings_map_hidden_categories_json',
  ]) {
    await db.customStatement('ALTER TABLE settings_table DROP COLUMN $column');
  }
  await db.customStatement('PRAGMA user_version = 132');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_locations_migration');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'rows written before the columns read as no locations, toggle off',
    () async {
      final seeded = await _seed(file);
      await _rewindToSchema131(file);

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final repository = DriftRankingRepository(db);
      final parent = (await repository.listParents(seeded.categoryId)).single;
      final category = await repository.getCategory(seeded.categoryId);

      expect(parent.id, seeded.id);
      expect(parent.locations, isEmpty);
      expect(category!.locationEnabled, isFalse);
      // The upgrade adds columns and touches nothing else on the row.
      expect(parent.title, 'Lazeez');
      expect(parent.overallScore, 4);
      expect(parent.tags, ['shawarma']);
    },
  );

  test('settings written before the map columns read as list view and '
      'nothing hidden — and take both afterwards', () async {
    final seed = AppDatabase(NativeDatabase(file));
    await DriftSettingsRepository(seed).getSettings();
    await seed.close();
    await _rewindToSchema132(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final repository = DriftSettingsRepository(upgraded);
    final settings = await repository.getSettings();
    expect(settings.rankingsMapViewCategories, isEmpty);
    expect(settings.rankingsMapHiddenCategories, isEmpty);
    await repository.saveSettings(
      settings.copyWith(
        rankingsMapViewCategories: const ['a'],
        rankingsMapHiddenCategories: const ['b'],
      ),
    );
    await repository.saveSettings(settings.copyWith(showQuotes: false));
    await upgraded.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final reopened = await DriftSettingsRepository(db).getSettings();
    expect(reopened.rankingsMapViewCategories, isEmpty);
    expect(reopened.showQuotes, isFalse);
  });

  test('a schema-133 database loses the stored map viewport column and '
      'gains the device location, which a whole-settings save leaves '
      'alone', () async {
    final seed = AppDatabase(NativeDatabase(file));
    await DriftSettingsRepository(seed).getSettings();
    await seed.customStatement(
      'ALTER TABLE settings_table ADD COLUMN rankings_map_viewport_json TEXT',
    );
    await seed.customStatement(
      "UPDATE settings_table SET rankings_map_viewport_json = '[43.5,-80.5,12]'",
    );
    for (final column in [
      'rankings_device_latitude',
      'rankings_device_longitude',
    ]) {
      await seed.customStatement(
        'ALTER TABLE settings_table DROP COLUMN $column',
      );
    }
    await seed.customStatement('PRAGMA user_version = 133');
    await seed.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repository = DriftSettingsRepository(db);
    final settings = await repository.getSettings();
    expect(settings.rankingsMapViewCategories, isEmpty);
    expect(settings.rankingsDeviceLocation, isNull);
    await repository.saveRankingsDeviceLocation((
      latitude: 43.47,
      longitude: -80.54,
    ));
    // A whole-settings save from a copy read before the fix must not put the
    // old location back.
    await repository.saveSettings(settings.copyWith(showQuotes: false));
    expect((await repository.getSettings()).rankingsDeviceLocation, (
      latitude: 43.47,
      longitude: -80.54,
    ));
    final column = await db
        .customSelect(
          "SELECT 1 FROM pragma_table_info('settings_table') "
          "WHERE name = 'rankings_map_viewport_json'",
        )
        .get();
    expect(column, isEmpty);
  });

  test('locations and the toggle written after the upgrade survive a '
      'reopen', () async {
    final seeded = await _seed(file);
    await _rewindToSchema131(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final repository = DriftRankingRepository(upgraded);
    final parent = (await repository.listParents(seeded.categoryId)).single;
    await repository.upsertParent(
      parent.copyWith(
        locations: const [
          RankingLocation(
            id: 'x',
            latitude: 43.4834,
            longitude: -80.526,
            address: '384 King Street North',
            label: 'King St',
          ),
        ],
      ),
    );
    final category = await repository.getCategory(seeded.categoryId);
    await repository.upsertCategory(category!.copyWith(locationEnabled: true));
    await upgraded.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final reopened = DriftRankingRepository(db);
    final location = (await reopened.listParents(
      seeded.categoryId,
    )).single.locations.single;
    expect(location.id, 'x');
    expect(location.latitude, 43.4834);
    expect(location.longitude, -80.526);
    expect(location.address, '384 King Street North');
    expect(location.label, 'King St');
    expect(
      (await reopened.getCategory(seeded.categoryId))!.locationEnabled,
      isTrue,
    );
  });
}

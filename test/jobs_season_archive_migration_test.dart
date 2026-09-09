// Schema 91 splits "archived" off "has a season". Before it, an application
// was archived iff it carried a season id at all; after it, archiving is a
// field on the season and a season is just the cycle you filed something
// under. Existing databases carry rows written under the old meaning, and the
// upgrade has to leave them intact — not merely not crash.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';

/// Rewinds a schema-91 database to look like a schema-90 one: drops the column
/// the upgrade adds and resets user_version, so reopening it runs the real
/// onUpgrade path rather than a hand-written approximation of it.
Future<void> _rewindToSchema90(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE job_seasons_table DROP COLUMN archived_at',
  );
  await db.customStatement('PRAGMA user_version = 90');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_season_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('the upgrade adds archived_at and keeps the seasons it finds', () async {
    final now = utcNow();
    var db = AppDatabase(NativeDatabase(file));
    var repo = DriftJobRepository(db);
    await repo.upsertSeason(
      JobSeason(
        id: 'fall',
        name: 'Fall 2025',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertApplication(
      JobApplication(
        id: newId(),
        company: 'Tesla',
        title: 'SWE Intern',
        status: 'Applied',
        dateApplied: DateTime(2026, 8, 20),
        seasonIds: const ['fall'],
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.close();

    await _rewindToSchema90(file);

    db = AppDatabase(NativeDatabase(file));
    repo = DriftJobRepository(db);
    final seasons = await repo.listSeasons();
    final applications = await repo.listApplications();

    expect(seasons.single.name, 'Fall 2025');
    // Seasons come across still running. Under the old meaning this
    // application was archived purely for carrying a season id; now it is
    // back in the active list until the user retires the cycle themselves.
    expect(seasons.single.isArchived, isFalse);
    expect(applications.single.seasonIds, ['fall']);
    expect(
      jobIsArchived(applications.single, jobArchivedSeasonIds(seasons)),
      isFalse,
    );

    // And the new column is writable on the migrated table.
    await repo.upsertSeason(seasons.single.copyWith(archivedAt: utcNow()));
    expect((await repo.listSeasons()).single.isArchived, isTrue);
    await db.close();
  });

  test('the upgrade folds the one season column into the list', () async {
    // Schema 99 replaces `season_id` with `season_ids_json`, because an
    // application can now be filed under more than one cycle. The one season
    // an existing row carries has to come across as a one-entry list.
    final now = utcNow();
    var db = AppDatabase(NativeDatabase(file));
    var repo = DriftJobRepository(db);
    await repo.upsertSeason(
      JobSeason(id: 'fall', name: 'Fall 2025', createdAt: now, updatedAt: now),
    );
    await repo.upsertApplication(
      JobApplication(
        id: 'app-1',
        company: 'Tesla',
        title: 'SWE Intern',
        status: 'Applied',
        dateApplied: DateTime(2026, 8, 20),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.close();

    await _rewindToSchema98(file, applicationId: 'app-1', seasonId: 'fall');

    db = AppDatabase(NativeDatabase(file));
    repo = DriftJobRepository(db);
    final applications = await repo.listApplications();
    expect(applications.single.seasonIds, ['fall']);

    // And the row is writable on the migrated table, in both directions.
    await repo.upsertApplication(
      applications.single.copyWith(seasonIds: const ['fall', 'spring']),
    );
    expect(
      (await repo.listApplications()).single.seasonIds,
      ['fall', 'spring'],
    );
    await db.close();
  });

  test('the upgrade leaves a row with no season on an empty list', () async {
    final now = utcNow();
    var db = AppDatabase(NativeDatabase(file));
    var repo = DriftJobRepository(db);
    await repo.upsertApplication(
      JobApplication(
        id: 'app-1',
        company: 'Tesla',
        title: 'SWE Intern',
        status: 'Applied',
        dateApplied: DateTime(2026, 8, 20),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.close();

    await _rewindToSchema98(file, applicationId: 'app-1', seasonId: null);

    db = AppDatabase(NativeDatabase(file));
    repo = DriftJobRepository(db);
    expect((await repo.listApplications()).single.seasonIds, isEmpty);
    await db.close();
  });
}

/// Rewinds a schema-99 database to look like a schema-98 one: puts `season_id`
/// back, takes `season_ids_json` away and resets user_version, so reopening it
/// runs the real onUpgrade path rather than a hand-written approximation of
/// it. [seasonId] is the value the old column is left holding.
Future<void> _rewindToSchema98(
  File file, {
  required String applicationId,
  required String? seasonId,
}) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE job_applications_table DROP COLUMN season_ids_json',
  );
  await db.customStatement(
    'ALTER TABLE job_applications_table ADD COLUMN season_id TEXT NULL',
  );
  if (seasonId != null) {
    await db.customStatement(
      'UPDATE job_applications_table SET season_id = ? WHERE id = ?',
      [seasonId, applicationId],
    );
  }
  await db.customStatement('PRAGMA user_version = 98');
  await db.close();
}

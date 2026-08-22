import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/job_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';

void main() {
  late AppDatabase db;
  late DriftJobRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftJobRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<JobApplication> addApplication({
    String company = 'Datadog',
    String title = 'Software Engineer',
    String status = 'Applied',
    String? seasonId,
  }) async {
    final now = utcNow();
    final application = JobApplication(
      id: newId(),
      company: company,
      title: title,
      status: status,
      dateApplied: DateTime(2026, 8, 20),
      applicationUrl: 'https://example.com',
      notes: 'some notes',
      seasonId: seasonId,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertApplication(application);
    return application;
  }

  group('seeding', () {
    test('creates the seed stages and companies once', () async {
      await repo.ensureSeeded();
      final stages = await repo.listStages();
      expect(stages.map((s) => s.name), jobSeedStages);
      expect(await repo.listCompanies(), hasLength(jobSeedCompanies.length));
    });

    test('is idempotent', () async {
      await repo.ensureSeeded();
      await repo.ensureSeeded();
      expect(await repo.listStages(), hasLength(jobSeedStages.length));
    });

    test('does not resurrect stages the user deleted', () async {
      await repo.ensureSeeded();
      for (final stage in await repo.listStages()) {
        await repo.softDeleteStage(stage.id);
      }
      await repo.ensureSeeded();
      expect(await repo.listStages(), isEmpty);
    });
  });

  group('hard delete', () {
    test(
      'leaves a content-wiped tombstone rather than removing the row',
      () async {
        final application = await addApplication();
        final result = await repo.deleteApplication(application.id);

        expect(await repo.listApplications(), isEmpty);
        final all = await repo.listApplications(includeDeleted: true);
        expect(all, hasLength(1));
        expect(all.single.deletedAt, isNotNull);
        expect(all.single.company, isEmpty);
        expect(all.single.title, isEmpty);
        expect(all.single.notes, isNull);
        expect(all.single.applicationUrl, isNull);
        // The returned tombstone is what the caller pushes, so it has to carry
        // the same wiped content the row does.
        expect(result.application.company, isEmpty);
        expect(result.application.deletedAt, isNotNull);
      },
    );

    test('tombstones the status history with it', () async {
      final application = await addApplication();
      final now = utcNow();
      await repo.upsertStatusEvent(
        JobStatusEvent(
          id: newId(),
          applicationId: application.id,
          toStatus: 'Applied',
          changedAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final result = await repo.deleteApplication(application.id);

      expect(await repo.listStatusEvents(application.id), isEmpty);
      expect(result.events, hasLength(1));
      expect(result.events.single.deletedAt, isNotNull);
    });

    test('the tombstone is purged once retention has passed', () async {
      final application = await addApplication();
      await repo.deleteApplication(application.id);

      await repo.purgeExpiredDeleted(utcNow());
      expect(
        await repo.listApplications(includeDeleted: true),
        hasLength(1),
        reason: 'a fresh tombstone still has to reach the other devices',
      );

      await repo.purgeExpiredDeleted(utcNow().add(const Duration(days: 31)));
      expect(await repo.listApplications(includeDeleted: true), isEmpty);
    });
  });

  group('company suggestions', () {
    test('ensureCompany adds a name that is not already listed', () async {
      final added = await repo.ensureCompany('Stripe');
      expect(added, isNotNull);
      expect(await repo.listCompanies(), hasLength(1));
    });

    test('ensureCompany is a no-op for a case-insensitive match', () async {
      await repo.ensureCompany('Stripe');
      expect(await repo.ensureCompany('  stripe '), isNull);
      expect(await repo.listCompanies(), hasLength(1));
    });

    test('deleting a suggestion leaves applications untouched', () async {
      final application = await addApplication(company: 'Stripe');
      final added = await repo.ensureCompany('Stripe');
      await repo.softDeleteCompany(added!.id);

      expect(await repo.listCompanies(), isEmpty);
      final stored = await repo.getApplication(application.id);
      expect(stored!.company, 'Stripe');
    });
  });

  group('categories', () {
    test('deleting a category uncategorises its companies', () async {
      final now = utcNow();
      final category = JobCategory(
        id: newId(),
        name: 'Big Tech',
        colorValue: 0xFF3366CC,
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertCategory(category);
      final added = await repo.ensureCompany('Google');
      await repo.upsertCompany(added!.copyWith(categoryId: category.id));

      final orphaned = await repo.softDeleteCategory(category.id);

      expect(await repo.listCategories(), isEmpty);
      expect(orphaned, hasLength(1));
      expect(orphaned.single.categoryId, isNull);
      final stored = await repo.listCompanies();
      expect(stored.single.categoryId, isNull);
    });
  });

  group('seasons', () {
    test('deleting a season un-archives everything filed under it', () async {
      final now = utcNow();
      final season = JobSeason(
        id: newId(),
        name: 'Fall 2025',
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertSeason(season);
      final archived = await addApplication(seasonId: season.id);

      final released = await repo.softDeleteSeason(season.id);

      expect(await repo.listSeasons(), isEmpty);
      expect(released, hasLength(1));
      final stored = await repo.getApplication(archived.id);
      expect(stored!.seasonId, isNull);
      expect(stored.isArchived, isFalse);
    });
  });

  group('stages', () {
    test('reorderStages renumbers and returns only what moved', () async {
      await repo.ensureSeeded();
      final stages = await repo.listStages();
      final ids = [for (final stage in stages) stage.id];
      // Move the last stage to the front.
      final reordered = [ids.last, ...ids.take(ids.length - 1)];

      final written = await repo.reorderStages(reordered);

      expect(written, hasLength(stages.length));
      final after = await repo.listStages();
      expect(after.first.name, stages.last.name);
      expect(after.map((s) => s.sortOrder), [
        for (var i = 0; i < stages.length; i++) i,
      ]);
    });

    test('reordering into the same order writes nothing', () async {
      await repo.ensureSeeded();
      final ids = [for (final stage in await repo.listStages()) stage.id];
      expect(await repo.reorderStages(ids), isEmpty);
    });

    test('deleting a stage leaves its applications as orphans', () async {
      await repo.ensureSeeded();
      final applied = (await repo.listStages()).first;
      final application = await addApplication(status: applied.name);

      await repo.softDeleteStage(applied.id);

      expect(
        (await repo.listStages()).map((s) => s.name),
        isNot(contains(applied.name)),
      );
      final stored = await repo.getApplication(application.id);
      expect(stored!.status, applied.name);
    });
  });
}

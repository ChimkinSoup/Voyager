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
    List<String> seasonIds = const [],
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
      seasonIds: seasonIds,
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

  group('soft delete', () {
    test(
      'leaves a tombstone with its content intact rather than removing the row',
      () async {
        final application = await addApplication();
        final result = await repo.deleteApplication(application.id);

        expect(await repo.listApplications(), isEmpty);
        final all = await repo.listApplications(includeDeleted: true);
        expect(all, hasLength(1));
        expect(all.single.deletedAt, isNotNull);
        // The content is what an undo restores from, so the delete must not
        // blank it — this used to be a content wipe (§7.4).
        expect(all.single.company, application.company);
        expect(all.single.title, application.title);
        expect(all.single.status, application.status);
        // The returned tombstone is what the caller pushes, so it has to carry
        // the same content the row does.
        expect(result.application.company, application.company);
        expect(result.application.deletedAt, isNotNull);
      },
    );

    test('a restore round-trips at a version that outranks the tombstone',
        () async {
      final application = await addApplication();
      final tombstone = (await repo.deleteApplication(application.id)).application;

      // What JobsActions.restoreApplication writes: the pre-delete snapshot
      // rebuilt with no deletedAt. Rebuilt rather than copyWith'd, which reads
      // `deletedAt ?? this.deletedAt` and so cannot clear a tombstone.
      await repo.upsertApplication(
        JobApplication(
          id: application.id,
          createdAt: application.createdAt,
          updatedAt: utcNow(),
          version: application.version + 2,
          company: application.company,
          title: application.title,
          status: application.status,
          dateApplied: application.dateApplied,
          applicationUrl: application.applicationUrl,
          notes: application.notes,
          seasonIds: application.seasonIds,
        ),
      );

      final restored = await repo.getApplication(application.id);
      expect(restored, isNotNull);
      expect(restored!.deletedAt, isNull);
      expect(restored.title, application.title);
      expect(
        restored.version,
        greaterThan(tombstone.version),
        reason: 'or the tombstone wins the next sync and deletes it again',
      );
      expect(await repo.listApplications(), hasLength(1));
    });

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
      final archived = await addApplication(seasonIds: [season.id]);

      final released = await repo.softDeleteSeason(season.id);

      expect(await repo.listSeasons(), isEmpty);
      expect(released, hasLength(1));
      final stored = await repo.getApplication(archived.id);
      expect(stored!.seasonIds, isEmpty);
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

    test('a stage colour round-trips, and reordering keeps it', () async {
      await repo.ensureSeeded();
      final stages = await repo.listStages();
      expect(
        stages.map((stage) => stage.colorValue),
        everyElement(isNull),
        reason: 'a seeded stage has no colour until one is picked',
      );

      await repo.upsertStage(stages[1].copyWith(colorValue: 0xFF2E7D32));
      expect(
        (await repo.listStages())[1].colorValue,
        0xFF2E7D32,
      );

      // sortOrder is written through a hand-built companion, which is exactly
      // where a new column gets dropped.
      final ids = [for (final stage in stages) stage.id];
      await repo.reorderStages([ids.last, ...ids.take(ids.length - 1)]);
      final moved = (await repo.listStages()).firstWhere(
        (stage) => stage.id == ids[1],
      );
      expect(moved.colorValue, 0xFF2E7D32);
    });

    test('clearing a stage colour returns it to the derived one', () async {
      await repo.ensureSeeded();
      final stage = (await repo.listStages()).first;
      await repo.upsertStage(stage.copyWith(colorValue: 0xFF2E7D32));

      await repo.upsertStage(
        (await repo.listStages()).first.copyWith(clearColorValue: true),
      );

      expect((await repo.listStages()).first.colorValue, isNull);
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

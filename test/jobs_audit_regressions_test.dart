// Regressions for the Job Tracker audit (AUDIT.md), below the widget layer:
// the queries, the repository, the actions, the sync merge and the schema-111
// migration. The page-level ones — the Columns popover, the editor panel, the
// Track form — live beside the harnesses they need, in jobs_page_test.dart and
// jobs_smart_paste_test.dart.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/job_constants.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart' show kTagPaletteDark;
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/job_clipboard_parser.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/jobs_stage_colors.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 8, 1);

JobApplication _application({
  String id = 'app-1',
  String status = 'Applied',
  String? notes,
  int version = 1,
  DateTime? dateApplied,
}) => JobApplication(
  id: id,
  company: 'Datadog',
  title: 'Software Engineer',
  status: status,
  dateApplied: dateApplied ?? DateTime.utc(2026, 8, 20),
  notes: notes,
  version: version,
  createdAt: _now,
  updatedAt: _now,
);

Future<({ProviderContainer container, DriftJobRepository repo})>
_harness() async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  final repo = DriftJobRepository(db);
  await repo.ensureSeeded();
  return (container: container, repo: repo);
}

/// Throws on every timeline write, so a multi-row write fails part-way.
class _FailingEventsRepository extends DriftJobRepository {
  _FailingEventsRepository(super.db);

  @override
  Future<void> upsertStatusEvent(
    JobStatusEvent event, {
    bool recordLocalActivity = true,
  }) async => throw StateError('disk full');
}

void main() {
  group('saving an application', () {
    test('a stale copy writes only its own change over newer data', () async {
      final h = await _harness();
      final actions = JobsActions.detached(h.container);
      final opened = await actions.createApplication(
        company: 'Datadog',
        title: 'Software Engineer',
        status: 'Applied',
      );

      // The table moves the status while the panel still holds `opened`.
      await actions.saveApplication(
        opened.copyWith(status: 'Interview'),
        previous: opened,
      );
      // The panel's next keystroke, diffed against its stale copy.
      await actions.saveApplication(
        opened.copyWith(notes: 'Recruiter call Friday'),
        previous: opened,
      );

      final stored = (await h.repo.getApplication(opened.id))!;
      expect(stored.status, 'Interview');
      expect(stored.notes, 'Recruiter call Friday');
      final events = await h.repo.listStatusEvents(opened.id);
      expect(
        [for (final e in events) '${e.fromStatus} -> ${e.toStatus}'],
        ['null -> Applied', 'Applied -> Interview'],
      );
    });

    test('a pending save does not resurrect a deleted application', () async {
      final h = await _harness();
      final actions = JobsActions.detached(h.container);
      final opened = await actions.createApplication(
        company: 'Datadog',
        title: 'Software Engineer',
      );
      await actions.deleteApplication(opened);

      final written = await actions.saveApplication(
        opened.copyWith(notes: 'typed before the delete landed'),
        previous: opened,
      );

      expect(written, isNull);
      expect(await h.repo.listApplications(), isEmpty);
      expect((await h.repo.getApplication(opened.id))!.deletedAt, isNotNull);
    });

    test('a new application is dated at UTC midnight of the picked day', () async {
      final h = await _harness();
      final created = await JobsActions.detached(h.container).createApplication(
        company: 'Datadog',
        title: 'Software Engineer',
        dateApplied: DateTime(2026, 8, 26),
      );
      final stored = (await h.repo.getApplication(created.id))!;
      expect(stored.dateApplied, DateTime.utc(2026, 8, 26));
      expect(stored.dateApplied.isUtc, isTrue);
    });

    test('a failed timeline write leaves no half-created application', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = _FailingEventsRepository(db);
      final application = _application();

      await expectLater(
        repo.writeApplication(
          application,
          events: [
            JobStatusEvent(
              id: newId(),
              applicationId: application.id,
              toStatus: application.status,
              changedAt: _now,
              createdAt: _now,
              updatedAt: _now,
            ),
          ],
          registerCompany: 'Datadog',
        ),
        throwsStateError,
      );

      expect(await repo.listApplications(includeDeleted: true), isEmpty);
      expect(await repo.listCompanies(), isEmpty);
    });
  });

  group('stages, seasons and categories', () {
    test('adding or renaming onto a taken stage name is refused', () async {
      final h = await _harness();
      final actions = JobsActions.detached(h.container);

      expect(await actions.addStage('  interview '), isFalse);
      final applied = (await h.repo.listStages()).first;
      expect(await actions.renameStage(applied, 'REJECTED'), isFalse);
      expect(
        (await h.repo.listStages()).map((s) => s.name),
        jobSeedStages,
        reason: 'neither refusal writes anything',
      );

      expect(await actions.addStage('Offer'), isTrue);
      expect((await h.repo.listStages()).last.name, 'Offer');
    });

    test('a soft delete bumps the version it writes and returns it', () async {
      final h = await _harness();
      final stage = (await h.repo.listStages()).first;

      final tombstone = (await h.repo.softDeleteStage(stage.id))!;

      final onDisk = (await h.repo.listStages(
        includeDeleted: true,
      )).firstWhere((s) => s.id == stage.id);
      expect(tombstone.version, stage.version + 1);
      expect(onDisk.version, tombstone.version);
      expect(onDisk.deletedAt, isNotNull);
      expect(await h.repo.softDeleteStage(stage.id), isNull);
    });

    test('a season added after a delete does not share a sort order', () async {
      final h = await _harness();
      final actions = JobsActions.detached(h.container);
      for (final name in ['Fall 2025', 'Fall 2026', 'Winter 2027']) {
        await actions.addSeason(name);
      }
      await actions.deleteSeason((await h.repo.listSeasons()).first);
      await actions.addSeason('Summer 2027');

      final orders = [for (final s in await h.repo.listSeasons()) s.sortOrder];
      expect(orders.toSet(), hasLength(orders.length));
      expect(
        (await h.repo.listSeasons()).map((s) => s.name),
        ['Fall 2026', 'Winter 2027', 'Summer 2027'],
      );
    });
  });

  group('seeding', () {
    test('seeds carry name-derived ids, and those ids are unique', () async {
      final h = await _harness();
      final stages = await h.repo.listStages();
      expect(stages.first.id, 'seed-stage-applied');
      expect(stages[1].id, 'seed-stage-online-assessment');
      final ids = [
        for (final name in jobSeedCompanies) jobSeedCompanyId(name),
      ];
      expect(ids.toSet(), hasLength(jobSeedCompanies.length));
    });

    test('a partial first pull does not stop the rest being seeded', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = DriftJobRepository(db);
      // Another device's rename of "Interview", pulled before seeding ran.
      await repo.upsertStage(
        JobStage(
          id: jobSeedStageId('Interview'),
          name: 'Interviewing',
          sortOrder: 2,
          version: 1,
          createdAt: jobSeedEpoch,
          updatedAt: _now,
        ),
      );

      await repo.ensureSeeded();

      expect((await repo.listStages()).map((s) => s.name), [
        'Applied',
        'Online Assessment',
        'Interviewing',
        'Accepted',
        'Rejected',
      ]);
    });

    test('a deleted seed survives the purge, so it is never re-seeded', () async {
      final h = await _harness();
      for (final stage in await h.repo.listStages()) {
        await h.repo.softDeleteStage(stage.id);
      }

      await h.repo.purgeExpiredDeleted(utcNow().add(const Duration(days: 60)));
      await h.repo.ensureSeeded();

      expect(await h.repo.listStages(), isEmpty);
    });
  });

  group('queries', () {
    test('the sparkline counts days before a DST change', () {
      // 1 Nov 2026 is the fall-back change in America/Toronto; the check is
      // vacuous on a machine in a zone without DST, and exact everywhere else.
      final series = jobDailyCounts([
        _application(dateApplied: DateTime.utc(2026, 10, 30)),
      ], now: DateTime(2026, 11, 10, 9));

      expect(series, hasLength(30));
      expect(series.every((d) => d.day.hour == 0), isTrue);
      expect(
        series.firstWhere((d) => d.day == DateTime(2026, 10, 30)).count,
        1,
      );
    });

    test('a stored day reads as that day, whatever the zone', () {
      expect(jobDayKey(DateTime.utc(2026, 8, 26)), DateTime(2026, 8, 26));
      // The legacy form: the instant of a local midnight.
      expect(
        jobCalendarDay(DateTime(2026, 8, 26).toUtc()),
        DateTime.utc(2026, 8, 26),
      );
      expect(jobCalendarDay(DateTime(2026, 8, 26)), DateTime.utc(2026, 8, 26));
    });

    test('two stages sharing a name are counted once', () {
      final stages = [
        for (final (i, name) in ['Applied', 'Interview', 'Interview'].indexed)
          JobStage(
            id: 's$i',
            name: name,
            sortOrder: i,
            createdAt: _now,
            updatedAt: _now,
          ),
      ];
      final counts = jobStatusCounts(stages, [
        _application(status: 'Interview'),
      ]);
      expect(counts, [(status: 'Interview', count: 1)]);
    });

    test('a link keeps a closing parenthesis that belongs to it', () {
      expect(
        normalizeJobUrl('https://en.wikipedia.org/wiki/Mercury_(planet)'),
        'https://en.wikipedia.org/wiki/Mercury_(planet)',
      );
      expect(
        normalizeJobUrl('https://acme.com/jobs/1).'),
        'https://acme.com/jobs/1',
      );
    });
  });

  test('a coloured stage is painted from the light ramp in light theme', () {
    final dark = kTagPaletteDark.first;
    final stage = JobStage(
      id: 's',
      name: 'Applied',
      colorValue: dark,
      createdAt: _now,
      updatedAt: _now,
    );
    final colors = JobStageColors(
      stages: [stage],
      fallback: Colors.blue,
      brightness: Brightness.light,
    );
    expect(colors.of('Applied'), Color(resolvePaletteColor(dark, Brightness.light)));
    expect(colors.of('Applied'), isNot(Color(dark)));
  });

  group('sync merge', () {
    test('concurrent edits to different fields both survive', () {
      final base = _application();
      final local = base.copyWith(notes: 'typed offline');
      final remote = base.copyWith(status: 'Offer');

      final result = resolveJobApplicationFromRemote(
        jobApplicationToFirestore(remote),
        base.id,
        local: local,
      );

      expect(result.merged.notes, 'typed offline');
      expect(result.merged.status, 'Offer');
      expect(result.localWon, isTrue, reason: 'the note has to go back up');
      expect(result.merged.version, 3);
    });

    test('a remote from a build without stamps merges whole', () {
      final local = _application(notes: 'mine', version: 3);
      final legacy = jobApplicationToFirestore(_application(version: 2))
        ..remove('fieldUpdatedAt')
        ..remove('fieldStampsVersion');

      final result = resolveJobApplicationFromRemote(
        legacy,
        local.id,
        local: local,
      );

      expect(result.merged.notes, 'mine');
      expect(result.localWon, isFalse);
    });

    test('a legacy local-midnight dateApplied arrives as its day', () {
      final data = jobApplicationToFirestore(_application())
        ..['dateApplied'] = DateTime(2026, 8, 26).toUtc().toIso8601String();

      final merged = mergeJobApplicationFromRemote(data, 'app-1');

      expect(merged.dateApplied, DateTime.utc(2026, 8, 26));
    });
  });

  group('schema 111 migration', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_jobs_111_test');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<AppDatabase> upgradeFrom110(
      Future<void> Function(AppDatabase db) seed,
    ) async {
      final db = AppDatabase(NativeDatabase(file));
      await seed(db);
      await db.customStatement('PRAGMA user_version = 110');
      await db.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      return reopened;
    }

    test('dates move to UTC midnight of the day they named', () async {
      final db = await upgradeFrom110((db) async {
        for (final (id, raw) in [
          // Written as local wall time with an offset.
          ('wall', '2026-09-09T00:00:00.000 -04:00'),
          // Written as the UTC instant of a local midnight.
          ('instant', DateTime(2026, 8, 26).toUtc().toIso8601String()),
        ]) {
          await db.customStatement(
            'INSERT INTO job_applications_table (id, company, title, status, '
            'date_applied, created_at, updated_at, version) '
            "VALUES (?, 'Acme', 'SWE', 'Applied', ?, ?, ?, 4)",
            [id, raw, _now.toIso8601String(), _now.toIso8601String()],
          );
        }
      });
      final repo = DriftJobRepository(db);

      final wall = (await repo.getApplication('wall'))!;
      final instant = (await repo.getApplication('instant'))!;
      expect(wall.dateApplied, DateTime.utc(2026, 9, 9));
      expect(instant.dateApplied, DateTime.utc(2026, 8, 26));
      expect(wall.version, 5, reason: 'or the next pull puts the old value back');
    });

    test('untouched seeds move onto seed ids without doubling', () async {
      const batch = '2026-08-22T16:11:15.032208Z';
      final db = await upgradeFrom110((db) async {
        Future<void> stage(
          String id,
          String name,
          int order, {
          int version = 0,
          bool deleted = false,
        }) => db.customStatement(
          'INSERT INTO job_stages_table (id, name, sort_order, created_at, '
          'updated_at, version, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [id, name, order, batch, batch, version, deleted ? batch : null],
        );
        await stage('old-applied', 'Applied', 0);
        await stage('old-oa', 'Online Assessment', 1);
        // Recoloured once, so pushed under its old id.
        await stage('old-interview', 'Interview', 2, version: 1);
        await stage('old-accepted', 'Accepted', 3);
        // Deleted by the old non-bumping soft delete.
        await stage('old-rejected', 'Rejected', 4, deleted: true);
      });
      final repo = DriftJobRepository(db);
      await repo.ensureSeeded();

      final live = await repo.listStages();
      expect(live.map((s) => s.name), [
        'Applied',
        'Online Assessment',
        'Interview',
        'Accepted',
      ]);
      expect(live.first.id, 'seed-stage-applied');
      expect(live[2].id, 'old-interview');
      final all = await repo.listStages(includeDeleted: true);
      expect(
        all.firstWhere((s) => s.id == 'seed-stage-rejected').deletedAt,
        isNotNull,
      );
      expect(
        all.firstWhere((s) => s.id == 'seed-stage-interview').deletedAt,
        isNotNull,
        reason: 'the placeholder that keeps a second Interview from seeding',
      );
    });

    test('tied sort orders are renumbered in their current order', () async {
      final db = await upgradeFrom110((db) async {
        for (final (id, order, created) in [
          ('fall', 2, '2026-08-28T14:46:27.928032Z'),
          ('winter', 2, '2026-08-28T14:46:38.346650Z'),
          ('summer', 3, '2026-08-28T14:46:42.071161Z'),
        ]) {
          await db.customStatement(
            'INSERT INTO job_seasons_table (id, name, sort_order, created_at, '
            'updated_at, version) VALUES (?, ?, ?, ?, ?, 0)',
            [id, id, order, created, created],
          );
        }
      });

      final seasons = await DriftJobRepository(db).listSeasons();
      expect(seasons.map((s) => s.id), ['fall', 'winter', 'summer']);
      expect(seasons.map((s) => s.sortOrder), [0, 1, 2]);
      expect(seasons.map((s) => s.version), [1, 1, 1]);
    });
  });
}

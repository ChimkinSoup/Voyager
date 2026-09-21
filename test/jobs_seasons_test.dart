// Cover for seasons as a cycle you file applications under, separate from
// archiving: the order is the user's own, archiving is a manual act on the
// season, and a retired season stays listed while it stops being offered.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_page.dart';

import 'fakes/fake_weather_api_client.dart';

JobSeason season(
  String id,
  String name, {
  int sortOrder = 0,
  DateTime? archivedAt,
}) {
  final now = utcNow();
  return JobSeason(
    id: id,
    name: name,
    sortOrder: sortOrder,
    archivedAt: archivedAt,
    createdAt: now,
    updatedAt: now,
  );
}

JobApplication application({
  required String company,
  List<String> seasonIds = const [],
}) {
  final now = utcNow();
  return JobApplication(
    id: newId(),
    company: company,
    title: 'SWE',
    status: 'Applied',
    dateApplied: DateTime(2026, 8, 20),
    seasonIds: seasonIds,
    createdAt: now,
    updatedAt: now,
  );
}

Future<ProviderContainer> pumpJobsPage(
  WidgetTester tester,
  Future<void> Function(DriftJobRepository repo) seed,
) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJobRepository(db);
  await repo.ensureSeeded();
  await seed(repo);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(jobApplicationsProvider.future);
  await container.read(jobStagesProvider.future);
  await container.read(jobCompaniesProvider.future);
  await container.read(jobCategoriesProvider.future);
  await container.read(jobSeasonsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: JobsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> openSeasonsTab(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Manage stages, categories and seasons'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Seasons'));
  await tester.pumpAndSettle();
}

void main() {
  group('repository', () {
    late AppDatabase db;
    late DriftJobRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftJobRepository(db);
    });
    tearDown(() => db.close());

    test('reorderSeasons renumbers and returns only what moved', () async {
      await repo.upsertSeason(season('a', 'Fall 2025'));
      await repo.upsertSeason(season('b', 'Spring 2026', sortOrder: 1));
      await repo.upsertSeason(season('c', 'Fall 2026', sortOrder: 2));

      final written = await repo.reorderSeasons(['c', 'a', 'b']);

      expect(written.map((s) => s.id), ['c', 'a', 'b']);
      expect((await repo.listSeasons()).map((s) => s.name), [
        'Fall 2026',
        'Fall 2025',
        'Spring 2026',
      ]);
    });

    test('reordering into the same order writes nothing', () async {
      await repo.upsertSeason(season('a', 'Fall 2025'));
      await repo.upsertSeason(season('b', 'Spring 2026', sortOrder: 1));

      expect(await repo.reorderSeasons(['a', 'b']), isEmpty);
    });

    test('archiving is a field on the season, and it round-trips', () async {
      await repo.upsertSeason(season('a', 'Fall 2025'));
      final stored = (await repo.listSeasons()).single;
      expect(stored.isArchived, isFalse);

      await repo.upsertSeason(stored.copyWith(archivedAt: utcNow()));
      expect((await repo.listSeasons()).single.isArchived, isTrue);

      await repo.upsertSeason(
        (await repo.listSeasons()).single.copyWith(clearArchivedAt: true),
      );
      expect((await repo.listSeasons()).single.isArchived, isFalse);
    });

    test('a retired season keeps its place in the list', () async {
      await repo.upsertSeason(season('a', 'Fall 2025', archivedAt: utcNow()));
      await repo.upsertSeason(season('b', 'Fall 2026', sortOrder: 1));

      // Listed, and still first — archiving takes it out of the picker, not
      // out of the Seasons section.
      expect((await repo.listSeasons()).map((s) => s.name), [
        'Fall 2025',
        'Fall 2026',
      ]);
    });
  });

  testWidgets('archiving a season retires everything filed under it', (
    tester,
  ) async {
    await pumpJobsPage(tester, (repo) async {
      await repo.upsertSeason(season('fall', 'Fall 2025'));
      await repo.upsertApplication(
        application(company: 'Stripe', seasonIds: const ['fall']),
      );
      await repo.upsertApplication(application(company: 'Datadog'));
    });

    // Filed under a season that is still running: both are in the list.
    expect(find.text('Stripe'), findsOneWidget);
    expect(find.text('Datadog'), findsOneWidget);

    await openSeasonsTab(tester);
    await tester.tap(find.byTooltip('Archive season'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // The season went, and its application went with it. Nothing about the
    // application itself changed.
    expect(find.text('Stripe'), findsNothing);
    expect(find.text('Datadog'), findsOneWidget);
  });

  testWidgets('an archived season is still listed, and can come back', (
    tester,
  ) async {
    await pumpJobsPage(tester, (repo) async {
      await repo.upsertSeason(
        season('fall', 'Fall 2025', archivedAt: utcNow()),
      );
      await repo.upsertApplication(
        application(company: 'Stripe', seasonIds: const ['fall']),
      );
    });

    expect(find.text('Stripe'), findsNothing);

    await openSeasonsTab(tester);
    // Still in the Seasons section, marked as archived.
    expect(find.text('Fall 2025'), findsOneWidget);

    await tester.tap(find.byTooltip('Unarchive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Stripe'), findsOneWidget);
  });

  testWidgets('the seasons list is drag-reorderable', (tester) async {
    await pumpJobsPage(tester, (repo) async {
      await repo.upsertSeason(season('a', 'Fall 2025'));
      await repo.upsertSeason(season('b', 'Fall 2026', sortOrder: 1));
    });

    await openSeasonsTab(tester);

    expect(find.byType(ReorderableListView), findsOneWidget);
    // One handle per season, the same affordance the stage list has.
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(2));
  });

  // AUDIT.md: each drag was computed from the list as it last loaded, so a
  // second drag before the reload overwrote the first.
  testWidgets('a second quick drag builds on the first', (tester) async {
    final container = await pumpJobsPage(tester, (repo) async {
      await repo.upsertSeason(season('a', 'Fall 2025'));
      await repo.upsertSeason(season('b', 'Winter 2026', sortOrder: 1));
      await repo.upsertSeason(season('c', 'Fall 2026', sortOrder: 2));
    });
    await openSeasonsTab(tester);

    void drag(int from, int to) => tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!(from, to);

    drag(2, 0); // c a b
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Fall 2026')).dy,
      lessThan(tester.getTopLeft(find.text('Fall 2025')).dy),
      reason: 'the dragged order shows before the write lands',
    );
    drag(2, 0); // b c a
    await tester.pumpAndSettle();

    final seasons = await container.read(jobSeasonsProvider.future);
    expect(seasons.map((s) => s.id), ['b', 'c', 'a']);
  });
}

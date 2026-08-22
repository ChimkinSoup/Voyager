// End-to-end cover for the Jobs page surface: the table renders what the
// filters leave, the header counts what the include-archived toggle scopes,
// tapping a row opens the editor panel, and delete is confirmed before it
// wipes anything.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_page.dart';

import 'fakes/fake_weather_api_client.dart';

Future<({AppDatabase db, ProviderContainer container})> pumpJobsPage(
  WidgetTester tester, {
  required Future<void> Function(DriftJobRepository repo) seed,
}) async {
  // Wide and tall: the header is a four-element row and the table sits beside
  // a 420px panel once one is open.
  tester.view.physicalSize = const Size(1600, 1200);
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
  // Warmed here rather than left to the first build: nothing in a widget test
  // drives these to completion on its own, and a cold read returns null.
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
  return (db: db, container: container);
}

JobApplication makeApplication({
  required String company,
  required String title,
  String status = 'Applied',
  DateTime? dateApplied,
  String? seasonId,
  String? notes,
}) {
  final now = utcNow();
  return JobApplication(
    id: newId(),
    company: company,
    title: title,
    status: status,
    dateApplied: dateApplied ?? DateTime(2026, 8, 20),
    notes: notes,
    seasonId: seasonId,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  testWidgets('renders a row per application', (tester) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'Software Engineer'),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Stripe', title: 'Backend Intern'),
        );
      },
    );

    expect(find.text('Datadog'), findsOneWidget);
    expect(find.text('Stripe'), findsOneWidget);
    expect(find.text('Software Engineer'), findsOneWidget);
  });

  testWidgets('the lifetime total counts archived applications too', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'season-1',
            name: 'Fall 2025',
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Stripe',
            title: 'Intern',
            seasonId: 'season-1',
          ),
        );
      },
    );

    // Two applications all-time, but the archived one is out of the list.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Datadog'), findsOneWidget);
    expect(find.text('Stripe'), findsNothing);

    await tester.tap(find.text('Include archived'));
    await tester.pumpAndSettle();

    expect(find.text('Stripe'), findsOneWidget);
  });

  testWidgets('per-status chips stay active-only when archived are shown', (
    tester,
  ) async {
    // §8.2: the chips count active applications whatever the toggle says.
    // Only the list, the sparkline and the Sankey follow it (§3.1, §8.3–8.4).
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'season-1',
            name: 'Fall 2025',
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE', status: 'Applied'),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Stripe',
            title: 'Intern',
            status: 'Applied',
            seasonId: 'season-1',
          ),
        );
      },
    );

    Finder appliedChipCount() => find.descendant(
      of: find
          .ancestor(of: find.text('Applied'), matching: find.byType(Row))
          .first,
      matching: find.text('1'),
    );

    expect(appliedChipCount(), findsOneWidget);

    await tester.tap(find.text('Include archived'));
    await tester.pumpAndSettle();

    expect(find.text('Stripe'), findsOneWidget, reason: 'the list follows it');
    expect(
      appliedChipCount(),
      findsOneWidget,
      reason: 'the chip count does not',
    );
  });

  testWidgets('search narrows the table by a substring', (tester) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Stripe', title: 'Intern'),
        );
      },
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Search company, title, notes or status'),
      'dog',
    );
    await tester.pumpAndSettle();

    expect(find.text('Datadog'), findsOneWidget);
    expect(find.text('Stripe'), findsNothing);
  });

  testWidgets('a status chip filters the table and clears again', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE', status: 'Applied'),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Stripe',
            title: 'Intern',
            status: 'Rejected',
          ),
        );
      },
    );

    await tester.tap(find.text('Rejected').first);
    await tester.pumpAndSettle();
    expect(find.text('Stripe'), findsOneWidget);
    expect(find.text('Datadog'), findsNothing);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Datadog'), findsOneWidget);
  });

  testWidgets('tapping a row opens the editor panel', (tester) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'Software Engineer',
            notes: 'referred',
          ),
        );
      },
    );

    await tester.tap(find.text('Software Engineer'));
    await tester.pumpAndSettle();

    // The panel's own controls, none of which the table renders.
    expect(find.text('Application URL'), findsOneWidget);
    expect(find.text('Active (not archived)'), findsOneWidget);
    expect(find.byTooltip('Duplicate application'), findsOneWidget);
  });

  testWidgets('delete asks first, then wipes the application', (tester) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'Software Engineer'),
        );
      },
    );

    await tester.tap(find.text('Software Engineer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete application'));
    await tester.pumpAndSettle();

    expect(find.text('Delete application?'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
      await DriftJobRepository(harness.db).listApplications(),
      hasLength(1),
      reason: 'cancelling has to leave the application alone',
    );

    await tester.tap(find.byTooltip('Delete application'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await DriftJobRepository(harness.db).listApplications(), isEmpty);
  });

  testWidgets('duplicate rows carry the soft warning marker', (tester) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'Software Engineer'),
        );
        await repo.upsertApplication(
          makeApplication(company: 'datadog', title: 'Software Engineer'),
        );
      },
    );

    expect(
      find.byTooltip('Another application has the same company and title'),
      findsNWidgets(2),
    );
  });

  testWidgets('an orphan status still renders and stays filterable', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE', status: 'Ghosted'),
        );
      },
    );

    expect(find.text('Ghosted'), findsWidgets);
    expect(find.text('Datadog'), findsOneWidget);
  });
}

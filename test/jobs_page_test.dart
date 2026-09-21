// End-to-end cover for the Jobs page surface: the table renders what the
// filters leave, the header counts what the include-archived toggle scopes,
// tapping a row opens the editor panel, and delete is confirmed before it
// wipes anything.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/core/constants/job_constants.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';
import 'package:voyager/features/jobs/jobs_edit_panel.dart';
import 'package:voyager/features/jobs/jobs_page.dart';
import 'package:voyager/features/jobs/jobs_providers.dart';
import 'package:voyager/features/jobs/jobs_table.dart';

import 'fakes/fake_weather_api_client.dart';

Future<({AppDatabase db, ProviderContainer container})> pumpJobsPage(
  WidgetTester tester, {
  required Future<void> Function(DriftJobRepository repo) seed,
  AppSettings Function(AppSettings settings)? settings,
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
  if (settings != null) {
    // Before the container exists, so the first settingsProvider read already
    // sees these rather than rebuilding the page onto them.
    final settingsRepo = DriftSettingsRepository(db);
    await settingsRepo.saveSettings(settings(await settingsRepo.getSettings()));
  }

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
  List<String> seasonIds = const [],
  String? notes,
  String? applicationUrl,
}) {
  final now = utcNow();
  return JobApplication(
    id: newId(),
    company: company,
    title: title,
    status: status,
    dateApplied: dateApplied ?? DateTime(2026, 8, 20),
    applicationUrl: applicationUrl,
    notes: notes,
    seasonIds: seasonIds,
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
            // Retired: filing an application under a season no longer
            // archives it on its own.
            archivedAt: now,
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
            seasonIds: const ['season-1'],
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
    // Only the list and the sparkline follow it (§3.1, §8.3).
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'season-1',
            name: 'Fall 2025',
            // Retired: filing an application under a season no longer
            // archives it on its own.
            archivedAt: now,
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
            seasonIds: const ['season-1'],
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
    expect(find.text('No season'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  // Delete is a row action on the right-click menu, not a button in the
  // editor panel: the panel edits the one application it is showing, and a
  // destructive control beside the fields being typed into is not where it
  // belongs.
  testWidgets('delete asks first, then wipes the application', (tester) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'Software Engineer'),
        );
      },
    );

    void tapDelete() {
      tester
          .widget<ContextMenuRegion>(find.byType(ContextMenuRegion))
          .itemsBuilder!()
          .firstWhere((item) => item.label == 'Delete')
          .onTap!();
    }

    tapDelete();
    await tester.pumpAndSettle();

    expect(find.text('Delete application?'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
      await DriftJobRepository(harness.db).listApplications(),
      hasLength(1),
      reason: 'cancelling has to leave the application alone',
    );

    tapDelete();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await DriftJobRepository(harness.db).listApplications(), isEmpty);
  });

  testWidgets('undoing a delete brings the application back in the editor', (
    tester,
  ) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'Software Engineer'),
        );
      },
    );

    tester
        .widget<ContextMenuRegion>(find.byType(ContextMenuRegion))
        .itemsBuilder!()
        .firstWhere((item) => item.label == 'Delete')
        .onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Deleted "Software Engineer at Datadog"'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restored = await DriftJobRepository(harness.db).listApplications();
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    // The panel's own controls, none of which the table renders — see
    // 'tapping a row opens the editor panel'.
    expect(
      find.byTooltip('Close'),
      findsOneWidget,
      reason: 'undo opens the application it brought back in the editor',
    );
    expect(find.text('Application URL'), findsOneWidget);
  });

  // Duplicate moved out of the panel with delete, onto the same menu.
  testWidgets('the row menu duplicates an application', (tester) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'Software Engineer'),
        );
      },
    );

    tester
        .widget<ContextMenuRegion>(find.byType(ContextMenuRegion))
        .itemsBuilder!()
        .firstWhere((item) => item.label == 'Duplicate')
        .onTap!();
    await tester.pumpAndSettle();

    final stored = await harness.container.read(jobApplicationsProvider.future);
    expect(stored, hasLength(2));
    expect(
      stored.map((application) => application.title),
      everyElement('Software Engineer'),
    );
  });

  testWidgets('the table names the season an application is filed under', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'live',
            name: 'Fall 2026',
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'SWE',
            seasonIds: const ['live'],
          ),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Stripe', title: 'Backend'),
        );
      },
    );

    expect(find.text('Season'), findsOneWidget, reason: 'the column header');
    expect(
      find.descendant(
        of: find.byType(JobsTableRow),
        matching: find.text('Fall 2026'),
      ),
      findsOneWidget,
    );
    // Filed under nothing reads as a dash rather than as a blank cell.
    expect(
      find.descendant(of: find.byType(JobsTableRow), matching: find.text('—')),
      findsOneWidget,
    );
  });

  // The capsule used to take the *company category* colour, which is a neutral
  // grey for any uncategorised company — so every capsule read as uncoloured.
  testWidgets('the status capsule takes the stage colour, not the company one', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final stages = await repo.listStages();
        await repo.upsertStage(stages.first.copyWith(colorValue: 0xFF2E7D32));
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'SWE',
            status: stages.first.name,
          ),
        );
      },
    );

    final capsule = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(JobsTableRow),
            matching: find.byType(Container),
          )
          .last,
    );
    final decoration = capsule.decoration! as BoxDecoration;
    // The fill is the stage's own colour at low alpha; the company here has no
    // category at all, so a company-coloured capsule could not be this hue.
    expect(decoration.color!.r, const Color(0xFF2E7D32).r);
    expect(decoration.color!.g, const Color(0xFF2E7D32).g);
    expect(decoration.color!.b, const Color(0xFF2E7D32).b);
  });

  testWidgets('duplicate rows carry the soft warning marker', (tester) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        // Same posting, reached by two links that differ only in noise.
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'Software Engineer',
            applicationUrl: 'https://www.datadog.com/jobs/1/',
          ),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'datadog',
            title: 'Software Engineer',
            applicationUrl: 'http://datadog.com/jobs/1',
          ),
        );
      },
    );

    expect(
      find.byTooltip('Another application links to the same posting URL'),
      findsNWidgets(2),
    );
  });

  testWidgets('two roles under one title at one company are not flagged', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'Software Engineer',
            applicationUrl: 'https://datadog.com/jobs/1',
          ),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'Software Engineer',
            applicationUrl: 'https://datadog.com/jobs/2',
          ),
        );
      },
    );

    expect(
      find.byTooltip('Another application links to the same posting URL'),
      findsNothing,
    );
  });

  // The chart is a childless CustomPaint, which sizes to
  // `constraints.constrain(Size.zero)` — under a start-aligned Column's loose
  // cross-axis constraints that is zero width, and the painter then bails on
  // its own `size.width <= 0` guard and draws nothing at all.
  testWidgets('the header chart is laid out with a paintable width', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'SWE',
            dateApplied: DateTime.now(),
          ),
        );
      },
    );

    expect(tester.getSize(find.byType(JobsSparkline)).width, greaterThan(0));
  });

  testWidgets('a season only archives its applications once it is retired', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'live',
            name: 'Fall 2026',
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Stripe',
            title: 'Intern',
            seasonIds: const ['live'],
          ),
        );
      },
    );

    // Filed under a season, but the season is still running — so it is not
    // archived and the default list still shows it.
    expect(find.text('Stripe'), findsOneWidget);
  });

  testWidgets('a row in one ended cycle and one live one stays on the list', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'retired',
            name: 'Fall 2025',
            archivedAt: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertSeason(
          JobSeason(
            id: 'live',
            name: 'Fall 2026',
            createdAt: now,
            updatedAt: now,
          ),
        );
        // Only in the ended cycle: archived.
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'SWE',
            seasonIds: const ['retired'],
          ),
        );
        // In the ended one *and* one still running: still in play.
        await repo.upsertApplication(
          makeApplication(
            company: 'Stripe',
            title: 'Intern',
            seasonIds: const ['retired', 'live'],
          ),
        );
      },
    );

    expect(find.text('Datadog'), findsNothing);
    expect(find.text('Stripe'), findsOneWidget);
    // The season column names both, in the Seasons list's own order.
    expect(find.text('Fall 2025, Fall 2026'), findsOneWidget);
  });

  testWidgets('the editor panel files one application under two seasons', (
    tester,
  ) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'a',
            name: 'Fall 2026',
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertSeason(
          JobSeason(
            id: 'b',
            name: 'Spring 2027',
            sortOrder: 1,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
      },
    );

    await tester.tap(find.text('Datadog'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('No season'));
    await tester.pumpAndSettle();
    // The picker stays open, so both are ticked without reopening it.
    await tester.tap(find.text('Spring 2027').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fall 2026').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ModalBarrier).last);
    await tester.pumpAndSettle();

    final stored = await harness.container.read(jobApplicationsProvider.future);
    // Stored in the Seasons list's order, not the order they were ticked.
    expect(stored.single.seasonIds, ['a', 'b']);
    // And the pill counts rather than trying to name both.
    expect(find.text('2 seasons'), findsOneWidget);
  });

  testWidgets('clicking the status capsule edits the status in place', (
    tester,
  ) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
      },
    );

    // The capsule inside the row, not the header chip of the same name.
    await tester.tap(
      find.descendant(
        of: find.byType(JobsTableRow),
        matching: find.text('Applied'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Online Assessment').last);
    await tester.pumpAndSettle();

    final stored = await harness.container.read(jobApplicationsProvider.future);
    expect(stored.single.status, 'Online Assessment');
    // The panel was never opened — the capsule is the whole interaction.
    expect(find.text('Application URL'), findsNothing);
  });

  testWidgets('the row menu omits the URL entry when there is no URL', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
      },
    );

    final region = tester.widget<ContextMenuRegion>(
      find.byType(ContextMenuRegion),
    );
    final labels = region.itemsBuilder!().map((item) => item.label).toList();

    expect(labels, ['Status', 'Seasons', 'Duplicate', 'Delete']);
  });

  testWidgets('the row menu offers the URL, the stages and the seasons', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'live',
            name: 'Fall 2026',
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertSeason(
          JobSeason(
            id: 'retired',
            name: 'Fall 2025',
            archivedAt: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(
            company: 'Datadog',
            title: 'SWE',
            applicationUrl: 'https://example.com/job',
          ),
        );
      },
    );

    // Opened for real, so the itemsBuilder actually runs.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Datadog')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Open application URL'), findsOneWidget);
    expect(find.text('Seasons'), findsOneWidget);

    final region = tester.widget<ContextMenuRegion>(
      find.byType(ContextMenuRegion),
    );
    final items = region.itemsBuilder!();
    final seasons = items
        .firstWhere((item) => item.label == 'Seasons')
        .children!
        .map((item) => item.label);
    // A retired season is not somewhere to move an application *to*.
    expect(seasons, ['No season', 'Fall 2026']);
  });

  testWidgets('the row menu moves an application into a season', (
    tester,
  ) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        final now = utcNow();
        await repo.upsertSeason(
          JobSeason(
            id: 'live',
            name: 'Fall 2026',
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
      },
    );

    final region = tester.widget<ContextMenuRegion>(
      find.byType(ContextMenuRegion),
    );
    final seasons = region.itemsBuilder!()
        .firstWhere((item) => item.label == 'Seasons')
        .children!;
    seasons.firstWhere((item) => item.label == 'Fall 2026').onTap!();
    await tester.pumpAndSettle();

    final stored = await harness.container.read(jobApplicationsProvider.future);
    expect(stored.single.seasonIds, ['live']);
    // Moved, not archived: the season it landed in is still running.
    expect(find.text('Datadog'), findsOneWidget);
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

  testWidgets('the header offers a copy button per filled profile slot', (
    tester,
  ) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Stripe', title: 'SWE'),
        );
      },
      // Portfolio deliberately left unset: an empty slot gets no button.
      settings: (s) => s.copyWith(
        jobProfileLinkedInUrl: 'https://linkedin.com/in/juno',
        jobProfileGitHubUrl: 'https://github.com/juno',
      ),
    );

    expect(find.byTooltip('Copy LinkedIn URL'), findsOneWidget);
    expect(find.byTooltip('Copy GitHub URL'), findsOneWidget);
    expect(find.byTooltip('Copy Portfolio URL'), findsNothing);

    await tester.tap(find.byTooltip('Copy GitHub URL'));
    await tester.pumpAndSettle();

    expect(copied, ['https://github.com/juno']);
    expect(find.text('GitHub copied'), findsOneWidget);
  });

  testWidgets('the header shows no copy group when every slot is unset', (
    tester,
  ) async {
    await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Stripe', title: 'SWE'),
        );
      },
    );

    expect(find.byTooltip('Copy LinkedIn URL'), findsNothing);
    expect(find.byTooltip('Copy GitHub URL'), findsNothing);
    expect(find.byTooltip('Copy Portfolio URL'), findsNothing);
  });

  // AUDIT.md: the panel held the row it opened with and wrote it whole, so a
  // status set from the table was reverted by the panel's next keystroke.
  testWidgets(
    'a status set from the table survives an edit in the open panel',
    (tester) async {
      final harness = await pumpJobsPage(
        tester,
        seed: (repo) async {
          await repo.upsertApplication(
            makeApplication(company: 'Datadog', title: 'SWE'),
          );
        },
      );
      await tester.tap(find.text('SWE'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(JobsTableRow),
          matching: find.text('Applied'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Interview').last);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(JobsEditPanel),
          matching: find.text('Interview'),
        ),
        findsOneWidget,
        reason:
            'the panel adopts the change rather than showing the old status',
      );

      final notes = find
          .descendant(
            of: find.byType(JobsEditPanel),
            matching: find.byType(EditableText),
          )
          .last;
      await tester.enterText(notes, 'Recruiter call Friday');
      // Past the panel's 400ms autosave debounce.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      final stored = (await harness.container.read(
        jobApplicationsProvider.future,
      )).single;
      expect(stored.status, 'Interview');
      expect(stored.notes, 'Recruiter call Friday');
    },
  );

  // AUDIT.md: each toggle closed over the settings the popover opened with, so
  // the second one undid the first.
  testWidgets('two columns toggled from one open menu both stay hidden', (
    tester,
  ) async {
    final harness = await pumpJobsPage(
      tester,
      seed: (repo) async {
        await repo.upsertApplication(
          makeApplication(company: 'Datadog', title: 'SWE'),
        );
      },
    );

    await tester.tap(find.byTooltip('Columns'));
    await tester.pumpAndSettle();
    // The menu's entries, not the table header's labels of the same name.
    await tester.tap(find.text('Notes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season').last);
    await tester.pumpAndSettle();

    final settings = harness.container.read(settingsProvider).value!;
    expect(settings.jobsHiddenColumns.toSet(), {
      JobColumn.notes.id,
      JobColumn.season.id,
    });
  });

  // The name-taken toast carries no actions and used to carry no dwell, so it
  // sat on screen — click-through — for the life of the app.
  testWidgets('the duplicate stage name toast dismisses itself', (
    tester,
  ) async {
    await pumpJobsPage(tester, seed: (repo) async {});

    await tester.tap(find.byTooltip('Manage stages, categories and seasons'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New stage'));
    await tester.pumpAndSettle();
    // A seeded stage, so the name is already taken.
    await tester.enterText(find.byType(TextField).last, jobDefaultStage);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(
      find.text('A stage named "$jobDefaultStage" already exists'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists'), findsNothing);
  });
}

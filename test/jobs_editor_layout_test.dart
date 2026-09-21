// Layout cover for the jobs forms: the floating track window ends where the
// form ends, the date pill opens a calendar rather than an empty box, and the
// single-line fields are given room to be typed in.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_edit_panel.dart';
import 'package:voyager/features/jobs/jobs_page.dart';
import 'package:voyager/features/jobs/jobs_track_draft_store.dart';

import 'fakes/fake_weather_api_client.dart';

Future<AppDatabase> pumpPage(
  WidgetTester tester, {
  Future<void> Function(DriftJobRepository repo)? seed,
}) async {
  // Deliberately taller than either form needs: the point of the dead-space
  // check is that the window does *not* grow to fill what it is offered.
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJobRepository(db);
  await repo.ensureSeeded();
  await seed?.call(repo);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      jobsTrackDraftStoreProvider.overrideWithValue(
        MemoryJobsTrackDraftStore(),
      ),
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
  return db;
}

JobApplication makeApplication({String? applicationUrl}) {
  final now = utcNow();
  return JobApplication(
    id: newId(),
    company: 'Datadog',
    title: 'Software Engineer',
    status: 'Applied',
    dateApplied: DateTime(2026, 8, 20),
    applicationUrl: applicationUrl,
    createdAt: now,
    updatedAt: now,
  );
}

/// The field carrying [label]. Labels are *painted* by [NotchedFieldBorder]
/// rather than rendered as a Text, so the border widget is the anchor.
Finder fieldLabelled(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is NotchedFieldBorder && widget.label == label,
  ),
  matching: find.byType(TextField),
);

void main() {
  // The form used to live in a bottom sheet sized by its constraints, so a
  // window taller than the form left a band of empty surface below Save.
  testWidgets('the track window ends where the form ends', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    final windowHeight = tester
        .getSize(
          find.ancestor(
            of: find.text('Track an application'),
            matching: find.byType(GlassSurface),
          ),
        )
        .height;
    final saveBottom = tester
        .getRect(find.widgetWithText(GlassButton, 'Save'))
        .bottom;
    final windowBottom = tester
        .getRect(
          find.ancestor(
            of: find.text('Track an application'),
            matching: find.byType(GlassSurface),
          ),
        )
        .bottom;

    // The window is nowhere near the height it is allowed to take...
    expect(windowHeight, lessThan(1400 * 0.9));
    // ...and Save sits against its bottom edge, with only the form's own
    // closing padding between them.
    expect(windowBottom - saveBottom, lessThan(40));
  });

  // The calendar hangs its day grid off an Expanded. Opened in a popover with
  // no height, that grid got none either and the popover painted as an empty
  // box — which is what "the date popup is just white" was.
  testWidgets('the date pill opens a calendar with a laid-out grid', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // Found by its icon, not by position: the date capsule moved out of the
    // capsule row — which is now status and season — down to the foot of the
    // form, and an index would have silently started tapping the season.
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectorPill &&
            widget.icon == PhosphorIconsRegular.calendarBlank,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DateSelectorPopover), findsOneWidget);
    expect(
      tester.getSize(find.byType(DateSelectorPopover)).height,
      greaterThan(200),
    );
    // A day of the month the picker opened on, which only renders once the
    // grid has real height to lay out in.
    expect(find.text('15'), findsOneWidget);
  });

  testWidgets('the editor date pill opens a calendar too', (tester) async {
    await pumpPage(
      tester,
      seed: (repo) => repo.upsertApplication(makeApplication()),
    );
    await tester.tap(find.text('Software Engineer'));
    await tester.pumpAndSettle();

    // Found by its label, not by position: the date capsule moved out of the
    // capsule row at the top of the editor and onto the History heading at the
    // bottom, and an index would have silently started tapping the season.
    await tester.tap(find.widgetWithText(SelectorPill, 'Aug 20, 2026'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(DateSelectorPopover)).height,
      greaterThan(200),
    );
    expect(find.text('15'), findsOneWidget);
  });

  testWidgets('the single-line fields are taller than a dense field', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // A dense field is 8px of padding either side of a 14px line box, so 30.
    // These carry 14 instead, which is 42.
    for (final label in ['Company', 'Role title', 'Application URL']) {
      expect(
        tester.getSize(fieldLabelled(label)).height,
        greaterThan(40),
        reason: '$label should have room to be typed in',
      );
    }
  });

  // Both moved onto the row's right-click menu, and Close moved to the right.
  testWidgets('the panel header carries only a close, on the right', (
    tester,
  ) async {
    await pumpPage(
      tester,
      seed: (repo) => repo.upsertApplication(makeApplication()),
    );
    await tester.tap(find.text('Software Engineer'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Duplicate application'), findsNothing);
    expect(find.byTooltip('Delete application'), findsNothing);

    final panel = tester.getRect(find.byType(JobsEditPanel));
    final close = tester.getRect(find.byTooltip('Close'));
    expect(close.center.dx, greaterThan(panel.center.dx));
  });

  testWidgets('Open is a glass button, not a text button', (tester) async {
    await pumpPage(
      tester,
      seed: (repo) => repo.upsertApplication(
        makeApplication(applicationUrl: 'https://jobs.example.com/swe'),
      ),
    );
    await tester.tap(find.text('Software Engineer'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(GlassButton, 'Open'), findsOneWidget);
  });

  testWidgets('Start over is a glass button, not a text button', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldLabelled('Company'), 'Tesla');
    await tester.pumpAndSettle();
    // Reopening is what surfaces the draft banner.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(GlassButton, 'Start over'), findsOneWidget);
  });
}

// Clipboard sniff and smart paste on the Track form
// (JOBS_SMART_PASTE_HLD.md §7, §8, §9). The parser has its own tests; what
// these cover is what the form does with what it parsed — which fields get
// written, which are left alone, and what the chip takes back.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_page.dart';
import 'package:voyager/features/jobs/jobs_track_draft.dart';
import 'package:voyager/features/jobs/jobs_track_draft_store.dart';

import 'fakes/fake_weather_api_client.dart';

/// What the mocked platform clipboard hands back. Null is both "nothing
/// copied" and "an image was copied": neither has a text flavour.
String? clipboardText;

typedef _Harness = ({AppDatabase db, ProviderContainer container});

Future<_Harness> pumpJobs(
  WidgetTester tester, {
  Future<void> Function(DriftJobRepository repo)? seed,
  JobsTrackDraft? draft,
}) async {
  tester.view.physicalSize = const Size(1600, 1600);
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
        MemoryJobsTrackDraftStore()..draft = draft,
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
  return (db: db, container: container);
}

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

/// The field carrying [label]: the labels are painted by [NotchedFieldBorder]
/// rather than mounted as Text, so the border is the only anchor there is.
Finder fieldLabelled(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is NotchedFieldBorder && widget.label == label,
  ),
  matching: find.byType(TextField),
);

TextEditingController controllerFor(WidgetTester tester, String label) =>
    tester.widget<TextField>(fieldLabelled(label).first).controller!;

String fieldText(WidgetTester tester, String label) =>
    controllerFor(tester, label).text;

Future<void> pressPaste(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

Future<void> focusField(WidgetTester tester, String label) async {
  await tester.tap(fieldLabelled(label).first);
  await tester.pumpAndSettle();
}

JobApplication application({required String url}) {
  final now = utcNow();
  return JobApplication(
    id: newId(),
    company: 'Acme',
    title: 'Software Engineer',
    status: 'Applied',
    dateApplied: DateTime(2026, 8, 20),
    applicationUrl: url,
    seasonIds: const [],
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return clipboardText == null
                ? null
                : <String, dynamic>{'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('one copied string fills both boxes as the form opens', (
    tester,
  ) async {
    clipboardText = 'Software Engineer https://acme.com/jobs/1';
    await pumpJobs(tester);
    await openForm(tester);

    expect(fieldText(tester, 'Role title'), 'Software Engineer');
    expect(fieldText(tester, 'Application URL'), 'https://acme.com/jobs/1');
    expect(find.text('From clipboard'), findsOneWidget);
  });

  testWidgets('a URL copied without a scheme is filled in with one', (
    tester,
  ) async {
    clipboardText = 'boards.greenhouse.io/acme/jobs/1';
    await pumpJobs(tester);
    await openForm(tester);

    expect(
      fieldText(tester, 'Application URL'),
      'https://boards.greenhouse.io/acme/jobs/1',
    );
    expect(fieldText(tester, 'Role title'), isEmpty);
  });

  testWidgets('an empty clipboard leaves the form exactly as it was', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    expect(fieldText(tester, 'Role title'), isEmpty);
    expect(fieldText(tester, 'Application URL'), isEmpty);
    expect(find.text('From clipboard'), findsNothing);
  });

  testWidgets('a saved draft keeps its own title through the sniff', (
    tester,
  ) async {
    clipboardText = 'Software Engineer https://acme.com/jobs/1';
    await pumpJobs(
      tester,
      draft: JobsTrackDraft(title: 'Data Scientist', savedAt: utcNow()),
    );
    await openForm(tester);

    // The filled field is left alone; the empty one is still fair game.
    expect(fieldText(tester, 'Role title'), 'Data Scientist');
    expect(fieldText(tester, 'Application URL'), 'https://acme.com/jobs/1');
  });

  testWidgets('dismissing the chip clears only what the clipboard filled', (
    tester,
  ) async {
    clipboardText = 'Software Engineer https://acme.com/jobs/1';
    await pumpJobs(tester);
    await openForm(tester);

    // Typed over: this one is the user's now, whatever put it there first.
    await tester.enterText(fieldLabelled('Role title').first, 'Data Scientist');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Clear what the clipboard filled in'));
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Role title'), 'Data Scientist');
    expect(fieldText(tester, 'Application URL'), isEmpty);
    expect(find.text('From clipboard'), findsNothing);
  });

  testWidgets('the chip goes once every field it filled has been edited', (
    tester,
  ) async {
    clipboardText = 'https://acme.com/jobs/1';
    await pumpJobs(tester);
    await openForm(tester);
    expect(find.text('From clipboard'), findsOneWidget);

    await tester.enterText(
      fieldLabelled('Application URL').first,
      'https://acme.com/jobs/2',
    );
    await tester.pumpAndSettle();

    expect(find.text('From clipboard'), findsNothing);
  });

  testWidgets('a paste into the title box splits the URL out of it', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    clipboardText = 'Backend Engineer https://acme.com/jobs/1';
    await focusField(tester, 'Role title');
    await pressPaste(tester);

    expect(fieldText(tester, 'Role title'), 'Backend Engineer');
    expect(fieldText(tester, 'Application URL'), 'https://acme.com/jobs/1');
  });

  testWidgets('a paste into the URL box fills the empty title too', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    clipboardText = 'https://acme.com/jobs/1 Backend Engineer';
    await focusField(tester, 'Application URL');
    await pressPaste(tester);

    expect(fieldText(tester, 'Application URL'), 'https://acme.com/jobs/1');
    expect(fieldText(tester, 'Role title'), 'Backend Engineer');
  });

  testWidgets('text with no link stays in the URL box it was pasted into', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    // Nothing here reads as a link, and the user aimed at this box.
    clipboardText = 'ask the recruiter';
    await focusField(tester, 'Application URL');
    await pressPaste(tester);

    expect(fieldText(tester, 'Application URL'), 'ask the recruiter');
    expect(fieldText(tester, 'Role title'), isEmpty);
  });

  testWidgets('a paste into the middle of a title is an ordinary paste', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    await tester.enterText(
      fieldLabelled('Role title').first,
      'Senior Engineer',
    );
    await tester.pumpAndSettle();
    controllerFor(tester, 'Role title').selection =
        const TextSelection.collapsed(offset: 7);
    await tester.pump();

    clipboardText = 'Staff ';
    await pressPaste(tester);

    expect(fieldText(tester, 'Role title'), 'Senior Staff Engineer');
    expect(fieldText(tester, 'Application URL'), isEmpty);
  });

  testWidgets('a posting already tracked raises a hint, not a block', (
    tester,
  ) async {
    final harness = await pumpJobs(
      tester,
      seed: (repo) =>
          repo.upsertApplication(application(url: 'https://acme.com/jobs/1')),
    );
    await openForm(tester);

    await tester.enterText(fieldLabelled('Company').first, 'Acme');
    await tester.enterText(
      fieldLabelled('Role title').first,
      'Software Engineer',
    );
    await tester.enterText(
      fieldLabelled('Application URL').first,
      // The same posting, said differently: the hint compares normalised URLs.
      'http://www.acme.com/jobs/1/',
    );
    await tester.pumpAndSettle();

    expect(find.text('You have already tracked this posting'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = await harness.container.read(jobApplicationsProvider.future);
    expect(stored, hasLength(2));
  });

  // AUDIT.md: §5.3 says Start over is a fresh open, and a fresh open sniffs.
  testWidgets('Start over reads the clipboard again', (tester) async {
    clipboardText = 'Software Engineer https://acme.com/jobs/1';
    await pumpJobs(
      tester,
      draft: JobsTrackDraft(title: 'Data Scientist', savedAt: utcNow()),
    );
    await openForm(tester);
    expect(fieldText(tester, 'Role title'), 'Data Scientist');

    await tester.tap(find.text('Start over'));
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Role title'), 'Software Engineer');
    expect(fieldText(tester, 'Application URL'), 'https://acme.com/jobs/1');
  });

  // AUDIT.md: a draft's stage is checked against the live list, like its
  // seasons, so a stage deleted meanwhile is not saved as an orphan.
  testWidgets('a draft left on a stage that is gone opens on the first one', (
    tester,
  ) async {
    await pumpJobs(
      tester,
      draft: JobsTrackDraft(
        title: 'Data Scientist',
        status: 'Phone Screen',
        savedAt: utcNow(),
      ),
    );
    await openForm(tester);

    expect(find.text('Phone Screen'), findsNothing);
    expect(find.text('Applied'), findsWidgets);
  });
}

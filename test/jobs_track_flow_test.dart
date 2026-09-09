// Cover for the one-page "track an application" flow: nothing reaches the
// database until Save, the whole form is collected in one pass, and the draft
// slot carries a half-filled form across a close.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_page.dart';
import 'package:voyager/features/jobs/jobs_track_draft.dart';
import 'package:voyager/features/jobs/jobs_track_draft_store.dart';

import 'fakes/fake_weather_api_client.dart';

typedef _Harness = ({
  AppDatabase db,
  ProviderContainer container,
  MemoryJobsTrackDraftStore drafts,
});

/// The real slot is a file, so the read the Add button waits on takes some
/// wall time. [MemoryJobsTrackDraftStore] resolves in a microtask, which hides
/// the gap a second press has to land in.
class SlowJobsTrackDraftStore implements JobsTrackDraftStore {
  JobsTrackDraft? draft;
  var loads = 0;

  @override
  Future<JobsTrackDraft?> load() async {
    loads++;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return draft;
  }

  @override
  Future<void> save(JobsTrackDraft value) async => draft = value;

  @override
  Future<void> clear() async => draft = null;
}

Future<_Harness> pumpJobs(
  WidgetTester tester, {
  Future<void> Function(DriftJobRepository repo)? seed,
  JobsTrackDraft? draft,
  JobsTrackDraftStore? store,
}) async {
  // Tall enough for the whole form: the sheet takes 94% of the window and the
  // notes box alone is 180px.
  tester.view.physicalSize = const Size(1600, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJobRepository(db);
  await repo.ensureSeeded();
  await seed?.call(repo);

  final drafts = MemoryJobsTrackDraftStore()..draft = draft;
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      jobsTrackDraftStoreProvider.overrideWithValue(store ?? drafts),
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
  return (db: db, container: container, drafts: drafts);
}

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

/// The field carrying [label]. Labels here are *painted* by
/// [NotchedFieldBorder] rather than rendered as a Text, so there is no
/// find.text to hang a finder off — the border widget itself is the anchor.
Finder fieldLabelled(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is NotchedFieldBorder && widget.label == label,
  ),
  matching: find.byType(TextField),
);

Future<void> typeInto(
  WidgetTester tester,
  String label,
  String text,
) async {
  await tester.enterText(fieldLabelled(label).first, text);
  await tester.pump();
}

/// What the focused text field holds, which is how these tests say *which*
/// field the focus is on: the labels are painted rather than mounted as Text,
/// so there is nothing to read off the focused widget itself.
String? focusedFieldText(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .where((field) => field.focusNode.hasFocus)
    .map((field) => field.controller.text)
    .singleOrNull;

JobSeason season(String id, String name, int sortOrder) {
  final now = utcNow();
  return JobSeason(
    id: id,
    name: name,
    sortOrder: sortOrder,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  testWidgets('the form opens on one page with every field on it', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    expect(find.text('Track an application'), findsOneWidget);
    expect(fieldLabelled('Company'), findsOneWidget);
    expect(fieldLabelled('Role title'), findsOneWidget);
    expect(fieldLabelled('Application URL'), findsOneWidget);
    expect(fieldLabelled('Notes'), findsOneWidget);
    // Stage, date and season pills, all present before anything is saved.
    expect(find.text('Applied'), findsWidgets);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('nothing is written until Save is pressed', (tester) async {
    final harness = await pumpJobs(tester);
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');

    // Closed without saving: the old flow had already created the row by now.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    final stored = await harness.container.read(
      jobApplicationsProvider.future,
    );
    expect(stored, isEmpty);
  });

  testWidgets('Save writes the whole form in one go', (tester) async {
    final harness = await pumpJobs(
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
      },
    );
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');
    await typeInto(tester, 'Application URL', 'https://tesla.com/job');
    await typeInto(tester, 'Notes', 'referred by a friend');

    // The season is picked here, while tracking — not applied afterwards.
    await tester.tap(find.text('No season'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fall 2026').last);
    await tester.pumpAndSettle();
    // The picker stays open so several cycles can be ticked in one visit; the
    // user closes it by tapping away. Away from the form, here — a tap on the
    // form itself would land on what it hit as well as closing the picker.
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = await harness.container.read(
      jobApplicationsProvider.future,
    );
    expect(stored, hasLength(1));
    expect(stored.single.company, 'Tesla');
    expect(stored.single.title, 'SWE Intern');
    expect(stored.single.applicationUrl, 'https://tesla.com/job');
    expect(stored.single.notes, 'referred by a friend');
    expect(stored.single.seasonIds, ['live']);
    // Filed under a season, but that season is still running.
    expect(find.text('Tesla'), findsOneWidget);
  });

  testWidgets('Save lands with the season picker still open', (tester) async {
    final harness = await pumpJobs(
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
      },
    );
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');

    await tester.tap(find.text('No season'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fall 2026').last);
    await tester.pumpAndSettle();

    // One press, not three. The picker is still up, and the press that closes
    // it is the press that saves — it is not spent on the barrier.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Track an application'), findsNothing);
    final stored = await harness.container.read(
      jobApplicationsProvider.future,
    );
    expect(stored, hasLength(1));
    expect(stored.single.seasonIds, ['live']);
  });

  testWidgets('the season pill still closes the picker it opened', (
    tester,
  ) async {
    await pumpJobs(
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
      },
    );
    await openForm(tester);

    await tester.tap(find.text('No season').first);
    await tester.pumpAndSettle();
    expect(find.text('Fall 2026'), findsOneWidget);

    // The trigger is cut out of the pass-through region: a press there closes
    // the picker rather than closing and reopening it.
    await tester.tap(find.text('No season').first);
    await tester.pumpAndSettle();
    expect(find.text('Fall 2026'), findsNothing);
  });

  testWidgets('saving does not leave the editor panel open', (tester) async {
    await pumpJobs(tester);
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // There is nothing left to fill in, so the panel is not forced open.
    expect(find.byTooltip('Duplicate application'), findsNothing);
  });

  testWidgets('Save names the field that is missing', (tester) async {
    final harness = await pumpJobs(tester);
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('A role title is required'), findsOneWidget);
    expect(
      await harness.container.read(jobApplicationsProvider.future),
      isEmpty,
    );
  });

  testWidgets('closing a half-filled form leaves a draft behind', (
    tester,
  ) async {
    final harness = await pumpJobs(tester);
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(harness.drafts.draft, isNotNull);
    expect(harness.drafts.draft!.company, 'Tesla');
    expect(harness.drafts.draft!.title, 'SWE Intern');
  });

  testWidgets('a second press during the draft read opens nothing', (
    tester,
  ) async {
    // The Add button reads the draft slot before anything is on screen. Two
    // presses landing in that gap used to open two forms — and both would have
    // been reading and writing the one slot, so closing the first left the
    // second sitting there ready to overwrite what it had just saved.
    final slow = SlowJobsTrackDraftStore();
    await pumpJobs(tester, store: slow);

    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('Track an application'), findsNothing);
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(slow.loads, 1);
    expect(find.text('Track an application'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Track an application'), findsNothing);
  });

  testWidgets('a draft is picked back up the next time the form opens', (
    tester,
  ) async {
    await pumpJobs(
      tester,
      draft: JobsTrackDraft(
        company: 'Tesla',
        title: 'SWE Intern',
        savedAt: utcNow(),
      ),
    );
    await openForm(tester);

    expect(find.text('Picked up where you left off'), findsOneWidget);
    expect(find.text('Tesla'), findsOneWidget);
    expect(find.text('SWE Intern'), findsOneWidget);
  });

  testWidgets('Start over empties the form and clears the slot', (
    tester,
  ) async {
    final harness = await pumpJobs(
      tester,
      draft: JobsTrackDraft(
        company: 'Tesla',
        title: 'SWE Intern',
        savedAt: utcNow(),
      ),
    );
    await openForm(tester);

    await tester.tap(find.text('Start over'));
    await tester.pumpAndSettle();

    expect(find.text('Tesla'), findsNothing);
    expect(harness.drafts.draft, isNull);
  });

  testWidgets('a saved application clears the draft slot', (tester) async {
    final harness = await pumpJobs(tester);
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The work is filed; there is nothing left to recover.
    expect(harness.drafts.draft, isNull);
  });

  testWidgets('a retired season is not offered while tracking', (
    tester,
  ) async {
    await pumpJobs(
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
            sortOrder: 1,
            createdAt: now,
            updatedAt: now,
          ),
        );
      },
    );
    await openForm(tester);

    await tester.tap(find.text('No season'));
    await tester.pumpAndSettle();

    expect(find.text('Fall 2026'), findsWidgets);
    expect(find.text('Fall 2025'), findsNothing);
  });

  testWidgets('Enter walks company to role title to the URL box', (
    tester,
  ) async {
    await pumpJobs(tester);
    await openForm(tester);

    // Distinct content per field so the focused one can be named by what it
    // holds; the pills between Role title and Application URL are picked, not
    // typed, so Enter skips them.
    await typeInto(tester, 'Application URL', 'url-marker');
    await typeInto(tester, 'Role title', 'title-marker');
    // A company on no list, so the completion overlay is closed and Enter is
    // the field's own rather than the highlighted suggestion's.
    await typeInto(tester, 'Company', 'Zzyzx Holdings');
    await tester.pumpAndSettle();
    expect(focusedFieldText(tester), 'Zzyzx Holdings');

    // Enter on a single-line field reaches Flutter as the input action, not as
    // a raw key — which is what `onSubmitted` is hung off.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(focusedFieldText(tester), 'title-marker');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(focusedFieldText(tester), 'url-marker');
  });

  testWidgets('one application can be filed under several seasons', (
    tester,
  ) async {
    final harness = await pumpJobs(
      tester,
      seed: (repo) async {
        await repo.upsertSeason(season('a', 'Fall 2026', 0));
        await repo.upsertSeason(season('b', 'Spring 2027', 1));
      },
    );
    await openForm(tester);
    await typeInto(tester, 'Company', 'Tesla');
    await typeInto(tester, 'Role title', 'SWE Intern');

    await tester.tap(find.text('No season'));
    await tester.pumpAndSettle();
    // Both ticked without reopening: the list does not close on a tap.
    await tester.tap(find.text('Fall 2026').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spring 2027').last);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    // The pill counts once it has more names than it can show.
    expect(find.text('2 seasons'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = await harness.container.read(
      jobApplicationsProvider.future,
    );
    // In the Seasons list's own order, not the order they were ticked.
    expect(stored.single.seasonIds, ['a', 'b']);
  });

  testWidgets('the season picker follows the Seasons list order', (
    tester,
  ) async {
    await pumpJobs(
      tester,
      seed: (repo) async {
        // Deliberately not alphabetical and not creation order: the picker has
        // to follow the manual order the Seasons section is dragged into.
        await repo.upsertSeason(season('c', 'Winter 2027', 0));
        await repo.upsertSeason(season('a', 'Fall 2026', 1));
        await repo.upsertSeason(season('b', 'Spring 2027', 2));
      },
    );
    await openForm(tester);

    await tester.tap(find.text('No season'));
    await tester.pumpAndSettle();

    final listed = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where(
          (t) => const {
            'Winter 2027',
            'Fall 2026',
            'Spring 2027',
          }.contains(t),
        )
        .toList();
    expect(listed, ['Winter 2027', 'Fall 2026', 'Spring 2027']);
  });

  group('draft slot', () {
    test('a blob from another version reads as no draft', () {
      final json = JobsTrackDraft(company: 'Tesla', savedAt: utcNow()).toJson();
      json['version'] = kJobsTrackDraftVersion + 1;
      expect(JobsTrackDraft.fromJson(json), isNull);
    });

    test('a draft round-trips through JSON', () {
      final draft = JobsTrackDraft(
        company: 'Tesla',
        title: 'SWE Intern',
        status: 'Interview',
        applicationUrl: 'https://tesla.com/job',
        notes: 'referred',
        seasonIds: const ['live'],
        dateApplied: DateTime(2026, 8, 20),
        savedAt: utcNow(),
      );
      final restored = JobsTrackDraft.fromJson(draft.toJson())!;
      expect(restored.sameContentAs(draft), isTrue);
    });

    test('a season that has since gone is dropped on restore', () {
      final draft = JobsTrackDraft(
        seasonIds: const ['retired', 'live'],
        savedAt: utcNow(),
      );
      // Only the gone one goes; the cycle still running is kept.
      expect(draft.resolveSeasonIds(const {'live'}), ['live']);
      expect(draft.resolveSeasonIds(const {'retired', 'live'}), [
        'retired',
        'live',
      ]);
      expect(draft.resolveSeasonIds(const <String>{}), isEmpty);
    });

    test('a form with only pills on it is not work worth keeping', () {
      expect(
        JobsTrackDraft(status: 'Applied', savedAt: utcNow()).hasText,
        isFalse,
      );
      expect(JobsTrackDraft(company: 'Tesla', savedAt: utcNow()).hasText, true);
    });
  });
}

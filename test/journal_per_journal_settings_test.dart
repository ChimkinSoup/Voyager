// Per-journal settings: the mood bar, weather picker and quote each hide
// independently, a journal can opt its entries out of the combined list, and
// one journal can claim the page's opening view.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

/// Matches an entry's title only where the entry *list* renders it.
///
/// A bare `find.text` would also match the editor's title field, which carries
/// the selected entry's title — so an entry the list is supposed to be hiding
/// still turns up once the page auto-selects it.
Finder entryRow(String title) => find.descendant(
  of: find.byType(KeepAliveScrollList),
  matching: find.text(title),
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the mood bar is on by default', (tester) async {
    await pumpJournalPage(tester);

    expect(find.byType(MoodGradientSlider), findsOneWidget);
    expect(find.text('Mood'), findsOneWidget);
    await disposeJournalPage(tester);
  });

  testWidgets('showMood off removes the mood label and slider', (tester) async {
    await pumpJournalPage(
      tester,
      configureJournal: (journal) => journal.copyWith(showMood: false),
    );

    expect(find.byType(MoodGradientSlider), findsNothing);
    expect(find.text('Mood'), findsNothing);
    await disposeJournalPage(tester);
  });

  testWidgets('hiding the mood bar closes the gap instead of leaving one', (
    tester,
  ) async {
    // The row's right-hand controls are the ones that would drift: the mood
    // slider owns the row's only Expanded, so removing it without a stand-in
    // lets the date pill and trash slide left into the space it left.
    await pumpJournalPage(tester);
    final withMood = tester.getTopRight(find.byTooltip('Delete entry')).dx;
    await disposeJournalPage(tester);

    await pumpJournalPage(
      tester,
      configureJournal: (journal) => journal.copyWith(showMood: false),
    );
    final withoutMood = tester.getTopRight(find.byTooltip('Delete entry')).dx;
    await disposeJournalPage(tester);

    expect(withoutMood, withMood);
  });

  testWidgets('the weather picker is on by default', (tester) async {
    await pumpJournalPage(tester);

    expect(find.byTooltip('Weather'), findsOneWidget);
    await disposeJournalPage(tester);
  });

  testWidgets('showWeather off removes the weather picker but keeps the mood '
      'bar', (tester) async {
    await pumpJournalPage(
      tester,
      configureJournal: (journal) => journal.copyWith(showWeather: false),
    );

    expect(find.byTooltip('Weather'), findsNothing);
    expect(find.byType(MoodGradientSlider), findsOneWidget);
    await disposeJournalPage(tester);
  });

  testWidgets('hiding the mood bar does not touch what entries store', (
    tester,
  ) async {
    final db = await pumpJournalPage(
      tester,
      configureJournal: (journal) => journal.copyWith(showMood: false),
    );

    final entries = await DriftJournalRepository(db).listEntries();
    expect(entries.single.id, 'harness-entry');
    // Untouched moods stay unrecorded whether the bar is shown or not; the
    // slider is what defaults them to 5 on screen.
    expect(entries.single.mood, isNull);
    await disposeJournalPage(tester);
  });

  testWidgets('a journal opted out of the all-journals view is absent from '
      'the combined list', (tester) async {
    await pumpJournalPage(
      tester,
      showAllJournals: true,
      seedSecondJournal: true,
      configureJournal: (journal) => journal.copyWith(includeInAllView: false),
    );

    expect(find.text('All journals'), findsOneWidget);
    expect(entryRow('Second journal entry'), findsOneWidget);
    expect(entryRow('Seeded entry'), findsNothing);
    await disposeJournalPage(tester);
  });

  testWidgets('both journals show in the all-journals view by default', (
    tester,
  ) async {
    await pumpJournalPage(
      tester,
      showAllJournals: true,
      seedSecondJournal: true,
    );

    expect(entryRow('Second journal entry'), findsOneWidget);
    expect(entryRow('Seeded entry'), findsOneWidget);
    await disposeJournalPage(tester);
  });

  testWidgets('a default journal wins over the saved all-journals view', (
    tester,
  ) async {
    await pumpJournalPage(
      tester,
      showAllJournals: true,
      defaultJournalId: journalHarnessId,
    );

    expect(find.text('All journals'), findsNothing);
    await disposeJournalPage(tester);
  });

  testWidgets('a default journal wins over the last-viewed journal', (
    tester,
  ) async {
    // lastViewedJournalId is the harness journal; the default points at the
    // second one, and the default is what the page has to open into.
    await pumpJournalPage(
      tester,
      seedSecondJournal: true,
      defaultJournalId: journalHarnessSecondId,
    );

    expect(entryRow('Second journal entry'), findsOneWidget);
    expect(entryRow('Seeded entry'), findsNothing);
    await disposeJournalPage(tester);
  });

  testWidgets('a default journal pointing at a missing journal falls back to '
      'the last-viewed one', (tester) async {
    await pumpJournalPage(tester, defaultJournalId: 'no-such-journal');

    expect(entryRow('Seeded entry'), findsOneWidget);
    await disposeJournalPage(tester);
  });
}

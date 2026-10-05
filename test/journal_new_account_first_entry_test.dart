// A brand-new account opens the Journal page with no journal and no entry.
//
// BUG-003: the editor is on screen even with nothing selected, but every save
// path needs a selected entry, so text typed there never reached SQLite and
// was gone after a restart. Typing now files it under a new entry (and the
// default journal), carrying what is on screen.
//
// BUG-004: the default journal a first entry creates was written without
// refreshing the kept-alive journal list, so the page went on believing there
// were no journals: the header showed no journal and the entry list stayed
// empty until a restart.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

/// The Journal page keeps animations running, so `pumpAndSettle` never
/// returns. Enough frames for the debounced saves to land, instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('typing into the editor of a new account saves an entry', (
    tester,
  ) async {
    final db = await pumpJournalPage(tester, emptyAccount: true);
    final repo = DriftJournalRepository(db);

    await tester.enterText(
      find.byType(TagHighlightedTextField),
      'qa probe body text',
    );
    await settle(tester);
    await tester.enterText(find.byType(LabeledTextField), 'qa probe title');
    await settle(tester);

    final journals = await repo.listJournals();
    expect(journals.map((j) => j.id), [legacyJournalId]);
    final entries = await repo.listEntries();
    expect(entries, hasLength(1));
    expect(entries.single.journalId, legacyJournalId);
    expect(entries.single.body, 'qa probe body text');
    expect(entries.single.title, 'qa probe title');

    // Still in the editor, not wiped by the entry opening under it.
    expect(find.text('qa probe body text'), findsWidgets);
    expect(find.text('qa probe title'), findsWidgets);

    await disposeJournalPage(tester);
  });

  testWidgets('the first entry and its default journal show without restart', (
    tester,
  ) async {
    await pumpJournalPage(tester, emptyAccount: true);
    expect(find.text('Journal'), findsNothing);

    await tester.tap(find.text('New entry'));
    await settle(tester);
    await tester.enterText(find.byType(TagHighlightedTextField), 'first body');
    await settle(tester);

    // The default journal names the header...
    expect(find.text('Journal'), findsWidgets);
    // ...and the entry is listed as well as open in the editor.
    expect(find.text('first body'), findsNWidgets(2));

    await disposeJournalPage(tester);
  });
}

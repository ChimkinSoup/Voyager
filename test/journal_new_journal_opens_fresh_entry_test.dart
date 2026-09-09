// Creating a journal from Manage lands you in it, not in the last one.
//
// The page used to set the journal filter and stop there, which left the
// previous journal's entry sitting in the editor under the new journal's name
// — a row that could then be typed into and saved back to the journal the user
// thought they had left. Creating now goes through the same path as picking a
// journal from the switcher: flush the outgoing edits, then open a fresh entry
// in the journal now on screen.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/journal_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a journal created from Manage opens an empty entry', (
    tester,
  ) async {
    final db = await pumpJournalPage(
      tester,
      seedEntries: (now) => [
        JournalEntry(
          id: 'harness-entry',
          journalId: journalHarnessId,
          title: 'Belongs to the old journal',
          body: 'Old body',
          entryDate: now,
          timestamp: now,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    // The editor opens on the seeded entry.
    expect(find.text('Belongs to the old journal'), findsWidgets);

    await tester.tap(find.byTooltip('Manage journals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New journal'));
    await tester.pumpAndSettle();

    // The name prompt is the dialog on top of the Manage dialog.
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(EditableText),
      ),
      'Fresh journal',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    // Closing Manage is what hands the created id back to the page.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Nothing of the old journal's entry is left on screen: not in the list,
    // which is now scoped to the new journal, and not in the editor either.
    expect(find.text('Belongs to the old journal'), findsNothing);

    // And the entry the editor is showing is a real, empty row in the new
    // journal rather than a blanked view of the old one.
    final journals = await DriftJournalRepository(db).listJournals();
    final created = journals.firstWhere((j) => j.name == 'Fresh journal');
    final entries = await DriftJournalRepository(
      db,
    ).listEntries(journalId: created.id);
    expect(entries, hasLength(1));
    expect(entries.single.title, isEmpty);
    expect(entries.single.body, isEmpty);

    await disposeJournalPage(tester);
  });
}

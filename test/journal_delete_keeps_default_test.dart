// Deleting the default-view journal cleared the setting, so restoring the
// journal from the trash didn't bring it back — the same gap BUG-072 closed
// for to-do lists. The id is now left in place; the page already treats an id
// with no live journal behind it as no default.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('deleting the default-view journal keeps the setting', (
    tester,
  ) async {
    final db = await pumpJournalPage(
      tester,
      seedSecondJournal: true,
      defaultJournalId: journalHarnessId,
    );

    await tester.tap(find.byTooltip('Manage journals'));
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text(journalHarnessName).last,
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all entries'));
    await tester.pumpAndSettle();

    final deleted = await DriftJournalRepository(
      db,
    ).getJournal(journalHarnessId);
    expect(deleted!.deletedAt, isNotNull);
    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultJournalId,
      journalHarnessId,
    );

    await disposeJournalPage(tester);
  });
}

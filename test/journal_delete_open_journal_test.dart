// Deleting the open journal with "delete all entries" left its trashed entry
// in the editor, and what was typed there was saved into the trashed row
// (BUG-047).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  // On a new account "Beta" is made first, as the last journal can't be
  // deleted; it is the empty journal the page falls back to.
  for (final emptyAccount in [false, true]) {
    testWidgets(
      'deleting the open journal takes its entry out of the editor '
      '(${emptyAccount ? 'new account' : 'falls back to a journal with entries'})',
      (tester) async {
        final db = await pumpJournalPage(tester, emptyAccount: emptyAccount);

        // Create "Gamma"; closing Manage opens it with a new entry.
        await tester.tap(find.byTooltip('Manage journals'));
        await tester.pumpAndSettle();
        for (final name in [if (emptyAccount) 'Beta', 'Gamma']) {
          await tester.tap(find.text('New journal'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byType(AlertDialog).last,
              matching: find.byType(EditableText),
            ),
            name,
          );
          await tester.tap(find.text('Create'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Close'));
        await _pumpFrames(tester, 8);

        await tester.enterText(find.byType(LabeledTextField), 'Gamma entry');
        await tester.enterText(
          find.byType(TagHighlightedTextField),
          'Gamma body text',
        );
        await _pumpFrames(tester, 30);

        final repo = DriftJournalRepository(db);
        final gamma = (await repo.listJournals()).firstWhere(
          (j) => j.name == 'Gamma',
        );
        final gammaEntry = (await repo.listEntries(journalId: gamma.id)).single;
        expect(gammaEntry.body, 'Gamma body text');

        // Gear → Gamma ⋮ → Delete → "Delete all entries" → Close.
        await tester.tap(find.byTooltip('Manage journals'));
        await tester.pumpAndSettle();
        final row = find.ancestor(
          of: find.text('Gamma').last,
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
        await tester.tap(find.text('Close'));
        await _pumpFrames(tester, 8);

        expect(find.text('Gamma entry'), findsNothing);
        expect(find.text('Gamma body text'), findsNothing);
        final settings = await DriftSettingsRepository(db).getSettings();
        expect(settings.lastViewedJournalId, isNot(gamma.id));

        // Whatever the editor holds now, typing into it leaves the trashed row
        // alone.
        final body = find.byType(TagHighlightedTextField);
        if (body.evaluate().isNotEmpty) {
          await tester.enterText(body, 'typed after the delete');
          await _pumpFrames(tester, 30);
        }
        final trashed = (await repo.getEntry(gammaEntry.id))!;
        expect(trashed.deletedAt, isNotNull);
        expect(trashed.title, 'Gamma entry');
        expect(trashed.body, 'Gamma body text');

        await disposeJournalPage(tester);
      },
    );
  }
}

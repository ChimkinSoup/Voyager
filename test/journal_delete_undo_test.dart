// The undo toast on the Journal page's entry delete.
//
// Like the To-Do page, the list drops a deleted entry optimistically
// ([_optimisticallyHiddenEntryIds]) so the row goes the instant the confirm
// closes. A restore that only writes the row back would leave the entry on
// disk and still missing from the list, so both halves are asserted here.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/journal_page_harness.dart';

/// The Journal page keeps animations running, so `pumpAndSettle` never
/// returns. Enough frames for a dialog or a toast to land, instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('deleting an entry offers an undo that brings it back', (
    tester,
  ) async {
    final db = await pumpJournalPage(
      tester,
      // Two entries, so deleting one does not empty the journal and set the
      // page off creating a replacement.
      seedEntries: (now) => [
        for (var i = 0; i < 2; i++)
          JournalEntry(
            id: 'harness-entry-$i',
            journalId: journalHarnessId,
            title: 'Entry $i',
            body: '',
            entryDate: now.subtract(Duration(days: i)),
            timestamp: now.subtract(Duration(days: i)),
            createdAt: now,
            updatedAt: now,
          ),
      ],
    );
    final repo = DriftJournalRepository(db);

    await tester.tap(find.byTooltip('Delete entry'));
    await settle(tester);
    expect(find.text('Delete entry?'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await settle(tester);

    // Entry 0 is the newest, so it is the one the page opens on and deletes.
    final afterDelete = await repo.listEntries(journalId: journalHarnessId);
    expect(afterDelete.map((e) => e.title), isNot(contains('Entry 0')));
    expect(find.text('Deleted "Entry 0"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await settle(tester);

    final restored = (await repo.listEntries(
      journalId: journalHarnessId,
    )).where((e) => e.title == 'Entry 0');
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    expect(
      restored.single.version,
      greaterThan(1),
      reason: 'the restore has to outrank the tombstone on the next sync',
    );
    expect(
      find.text('Entry 0'),
      findsNWidgets(2),
      reason:
          'undo opens the entry it brought back — the delete had moved the '
          'editor onto Entry 1, so one match is the list row and the other '
          'the editor title',
    );

    await disposeJournalPage(tester);
  });

  testWidgets('the confirm dialog still stands in front of the delete', (
    tester,
  ) async {
    final db = await pumpJournalPage(tester);
    final repo = DriftJournalRepository(db);

    await tester.tap(find.byTooltip('Delete entry'));
    await settle(tester);
    await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
    await settle(tester);

    // Cancelling deletes nothing, and raises no offer to undo.
    expect(await repo.listEntries(journalId: journalHarnessId), hasLength(1));
    expect(find.text('Undo'), findsNothing);

    await disposeJournalPage(tester);
  });
}

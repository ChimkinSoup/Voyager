// The delete-journal dialog said "This journal has 1 entries", and its "Yes"
// button — which moves the entries — read as "yes, delete" (BUG-049).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/journal_page.dart';

import 'support/journal_page_harness.dart';

Future<void> _openDeleteDialog(WidgetTester tester) async {
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
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('one entry is "1 entry", and the buttons name their action', (
    tester,
  ) async {
    await pumpJournalPage(tester, seedSecondJournal: true);
    await _openDeleteDialog(tester);

    expect(
      find.text(
        'This journal has 1 entry. Move it to "Second", or delete everything.',
      ),
      findsOneWidget,
    );
    expect(find.text('Move to "Second"'), findsOneWidget);
    expect(find.text('Delete all entries'), findsOneWidget);
    expect(find.text('Yes'), findsNothing);

    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await disposeJournalPage(tester);
  });

  testWidgets('the move target is the default-view journal, by its current '
      'name', (tester) async {
    final db = await pumpJournalPage(
      tester,
      seedSecondJournal: true,
      defaultJournalId: legacyJournalId,
      seedEntries: (now) => [
        for (var i = 0; i < 2; i++)
          JournalEntry(
            id: 'harness-entry-$i',
            journalId: journalHarnessId,
            title: 'Entry $i',
            body: '',
            entryDate: now,
            timestamp: now,
            createdAt: now,
            updatedAt: now,
          ),
      ],
    );
    final now = DateTime.now().toUtc();
    await DriftJournalRepository(db).upsertJournal(
      Journal(
        id: legacyJournalId,
        name: 'Diary',
        createdAt: now,
        updatedAt: now,
      ),
    );
    ProviderScope.containerOf(
      tester.element(find.byType(JournalPage)),
    ).invalidate(journalsProvider);
    await tester.pumpAndSettle();

    await _openDeleteDialog(tester);

    expect(
      find.text(
        'This journal has 2 entries. Move them to "Diary", or delete '
        'everything.',
      ),
      findsOneWidget,
    );
    expect(find.text('Move to "Diary"'), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await disposeJournalPage(tester);
  });

  testWidgets('an empty journal offers a single Delete', (tester) async {
    await pumpJournalPage(
      tester,
      seedSecondJournal: true,
      seedEntries: (_) => const [],
    );
    await _openDeleteDialog(tester);

    expect(
      find.text('This journal has no entries and will be removed.'),
      findsOneWidget,
    );
    expect(find.textContaining('Move to'), findsNothing);
    expect(find.text('Delete all entries'), findsNothing);
    final dialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(of: dialog, matching: find.text('Delete')),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await disposeJournalPage(tester);
  });
}

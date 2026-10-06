// Creating the first journal also made an empty built-in "Journal" that could
// never be deleted (BUG-048). Now any journal but the last can be deleted, and
// "Move" sends its entries to the default-view journal or the oldest one left.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/journal_list_actions.dart';
import 'package:voyager/features/journal/journal_page.dart';

import 'support/journal_page_harness.dart';

Future<void> _openMenuOf(WidgetTester tester, String name) async {
  final row = find.ancestor(
    of: find.text(name).last,
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(
      of: row,
      matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the first journal is the only one, and as the last it has no '
      'Delete', (tester) async {
    final db = await pumpJournalPage(tester, emptyAccount: true);

    await tester.tap(find.byTooltip('Manage journals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New journal'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(EditableText),
      ),
      'Alpha',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final journals = await DriftJournalRepository(db).listJournals();
    expect(journals.map((j) => j.name), ['Alpha']);
    expect(journals.single.id, isNot(legacyJournalId));

    await _openMenuOf(tester, 'Alpha');
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);

    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await disposeJournalPage(tester);
  });

  testWidgets('the built-in "Journal" can be deleted, its entries moving to '
      'the journal left', (tester) async {
    final db = await pumpJournalPage(tester);
    final repo = DriftJournalRepository(db);
    final now = DateTime.now().toUtc();
    await repo.upsertJournal(
      Journal(
        id: legacyJournalId,
        name: 'Journal',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertEntry(
      JournalEntry(
        id: 'legacy-entry',
        journalId: legacyJournalId,
        title: 'Old entry',
        body: '',
        entryDate: now,
        timestamp: now,
        createdAt: now,
        updatedAt: now,
      ),
    );
    ProviderScope.containerOf(
      tester.element(find.byType(JournalPage)),
    ).invalidate(journalsProvider);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Manage journals'));
    await tester.pumpAndSettle();
    await _openMenuOf(tester, 'Journal');
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to "$journalHarnessName"'));
    await tester.pumpAndSettle();

    expect((await repo.listJournals()).map((j) => j.id), [journalHarnessId]);
    expect((await repo.getEntry('legacy-entry'))!.journalId, journalHarnessId);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await disposeJournalPage(tester);
  });

  group('fallbackJournalFor', () {
    final t0 = DateTime.utc(2026, 1, 1);
    Journal journal(String id, int day, {DateTime? deletedAt}) => Journal(
      id: id,
      name: id,
      createdAt: t0.add(Duration(days: day)),
      updatedAt: t0,
      deletedAt: deletedAt,
    );

    test('prefers the default-view journal, else the oldest live one', () {
      final journals = [
        journal('gone', 0, deletedAt: t0),
        journal('b', 2),
        journal('a', 1),
        journal('doomed', 0),
      ];
      expect(fallbackJournalFor(journals, excludingId: 'doomed')!.id, 'a');
      expect(
        fallbackJournalFor(
          journals,
          excludingId: 'doomed',
          defaultJournalId: 'b',
        )!.id,
        'b',
      );
      expect(
        fallbackJournalFor(
          journals,
          excludingId: 'doomed',
          defaultJournalId: 'doomed',
        )!.id,
        'a',
      );
    });

    test('is null for the last journal', () {
      expect(
        fallbackJournalFor([journal('only', 0)], excludingId: 'only'),
        isNull,
      );
    });
  });
}

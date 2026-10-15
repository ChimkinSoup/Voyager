// BUG-246: an entry deleted on another device while it was open in the Search
// popup. Saves into a deleted row are dropped, so the popup says so instead of
// losing what was typed without a word — and a publish owed by an earlier
// autosave must not write the popup's live copy back over the tombstone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/search_page_harness.dart';

const _entryId = 'search-entry';
const _deletedMessage = 'This entry was deleted, so the edit was not saved.';

List<JournalEntry> _seed(DateTime now) => [
  JournalEntry(
    id: _entryId,
    journalId: searchHarnessJournalId,
    title: 'Untouched title',
    body: 'Untouched body',
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
    version: 3,
  ),
];

Future<JournalEntry> _readEntry(AppDatabase db) async {
  final entry = await DriftJournalRepository(db).getEntry(_entryId);
  return entry!;
}

/// What a pull applying another device's deletion leaves on disk.
Future<void> _deleteElsewhere(AppDatabase db) async {
  final entry = await _readEntry(db);
  await DriftJournalRepository(db).upsertEntry(
    entry.copyWith(deletedAt: DateTime.now().toUtc()),
    recordLocalActivity: false,
  );
}

Future<void> _openEntryDialog(WidgetTester tester) async {
  await tester.tap(find.text('Untouched title'));
  await settle(tester);
  expect(find.text('Journal entry'), findsOneWidget);
}

Finder _titleField() => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(EditableText),
);

void main() {
  testWidgets('typing into an entry deleted elsewhere says it was not saved', (
    tester,
  ) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);
    await _deleteElsewhere(db);

    await tester.enterText(_titleField().first, 'Typed after the delete');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);

    expect(find.text(_deletedMessage), findsOneWidget);
    final after = await _readEntry(db);
    expect(after.deletedAt, isNotNull);
    expect(after.title, 'Untouched title');

    // Closed here rather than by the teardown, whose save raises the toast
    // again after the page is gone; then its timers run out.
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect((await _readEntry(db)).deletedAt, isNotNull);
    await tester.pump(const Duration(seconds: 10));
    await disposeSearchPage(tester);
  });

  testWidgets('closing after an autosave does not bring a deleted entry '
      'back', (tester) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Autosaved, then deleted');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect((await _readEntry(db)).title, 'Autosaved, then deleted');

    await _deleteElsewhere(db);
    // Nothing typed since the autosave: closing only publishes what it owes.
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect((await _readEntry(db)).deletedAt, isNotNull);
    expect(find.text(_deletedMessage), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    await disposeSearchPage(tester);
  });
}

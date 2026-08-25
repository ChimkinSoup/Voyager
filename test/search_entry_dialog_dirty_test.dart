// The Search result popup's write gate.
//
// Both cases here are ways the dialog wrote — or refused to write — without the
// user asking. They assert against SQLite rather than the widget tree: the
// dialog keeps its own copy of the text, so the damage is invisible until the
// row is read back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/search_page_harness.dart';

const _entryId = 'search-entry';

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
    // Null on purpose: the rows that predate the mood default still exist, and
    // the dialog coerces one to kDefaultMood purely so the slider has a
    // position. That coercion must not reach disk on its own.
    mood: null,
    version: 3,
  ),
];

Future<JournalEntry> _readEntry(AppDatabase db) async {
  final entry = await DriftJournalRepository(db).getEntry(_entryId);
  return entry!;
}

Future<void> _openEntryDialog(WidgetTester tester) async {
  await tester.tap(find.text('Untouched title'));
  await settle(tester);
  expect(find.text('Journal entry'), findsOneWidget);
}

/// The dialog's title field — the first editable in it, ahead of the body.
Finder _titleField() => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(EditableText),
);

void main() {
  testWidgets('opening and closing a result without editing writes nothing', (
    tester,
  ) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    final before = await _readEntry(db);

    await _openEntryDialog(tester);
    await tester.tap(find.text('Close'));
    await settle(tester);

    final after = await _readEntry(db);
    // A save here bumps the version, restamps updatedAt and — through
    // forceOverwriteJournalEntryText — deletes and re-seeds the entry's whole
    // remote operation log. None of that may happen for a mis-tap on the
    // barrier.
    expect(after.version, before.version);
    expect(after.updatedAt, before.updatedAt);
    expect(after.mood, isNull, reason: 'the display default must not persist');
    expect(after.weatherIcon, isNull);
    expect(after.title, 'Untouched title');
    expect(after.body, 'Untouched body');

    await disposeSearchPage(tester);
  });

  testWidgets('an edit after a lifecycle flush still saves on close', (
    tester,
  ) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    // What alt-tabbing away on desktop does: AppLifecycleState.inactive drains
    // the registry. The old code latched `_isSaved` here and skipped every
    // later save, so everything typed afterwards was dropped by Close and
    // Escape alike, silently and completely.
    await PendingFlushRegistry.instance.flushAll();
    await settle(tester);

    await tester.enterText(_titleField().first, 'Typed after the flush');
    await settle(tester);
    await tester.tap(find.text('Close'));
    await settle(tester);

    final after = await _readEntry(db);
    expect(after.title, 'Typed after the flush');
    expect(after.body, 'Untouched body');

    await disposeSearchPage(tester);
  });
}

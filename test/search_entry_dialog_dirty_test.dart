// The Search result popup's write gate.
//
// Every case here is a way the dialog wrote — or refused to write — something
// other than what the user asked for. They assert against SQLite rather than
// the widget tree: the dialog keeps its own copy of the text, so the damage is
// invisible until the row is read back.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
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
    await tester.tap(find.text('Cancel'));
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

  testWidgets('an edit after a lifecycle flush still saves', (tester) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    // What alt-tabbing away on desktop does: AppLifecycleState.inactive drains
    // the registry. The old code latched `_isSaved` here and skipped every
    // later save, so everything typed afterwards was dropped silently and
    // completely.
    await PendingFlushRegistry.instance.flushAll();
    await settle(tester);

    await tester.enterText(_titleField().first, 'Typed after the flush');
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);

    final after = await _readEntry(db);
    expect(after.title, 'Typed after the flush');
    expect(after.body, 'Untouched body');

    await disposeSearchPage(tester);
  });

  // Cancel is the way out that throws the session away: it puts the entry back
  // as it was opened. Everything else that ends the dialog — Save, Enter,
  // Escape, a click on the barrier, a lifecycle flush — is a write.
  testWidgets('Cancel discards what was typed', (tester) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    final before = await _readEntry(db);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Typed then thrown away');
    await settle(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    final after = await _readEntry(db);
    expect(after.title, 'Untouched title');
    expect(after.body, 'Untouched body');
    expect(after.version, before.version);
    expect(after.updatedAt, before.updatedAt);

    await disposeSearchPage(tester);
  });

  testWidgets('typing is autosaved while the dialog stays open', (
    tester,
  ) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Typed and left open');
    await settle(tester);
    expect((await _readEntry(db)).title, 'Untouched title');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);

    expect(find.text('Journal entry'), findsOneWidget);
    expect((await _readEntry(db)).title, 'Typed and left open');

    await disposeSearchPage(tester);
  });

  testWidgets('moving the caret does not push the autosave back', (
    tester,
  ) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Typed, then clicked around');
    await tester.pump(const Duration(milliseconds: 1000));
    final controller = tester
        .widget<EditableText>(_titleField().first)
        .controller;
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump(const Duration(milliseconds: 700));
    await settle(tester);

    // 1.7 s after the edit, 0.7 s after the caret moved.
    expect((await _readEntry(db)).title, 'Typed, then clicked around');

    await disposeSearchPage(tester);
  });

  testWidgets('Cancel after an autosave puts the entry back as opened', (
    tester,
  ) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Autosaved then cancelled');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect((await _readEntry(db)).title, 'Autosaved then cancelled');

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    final after = await _readEntry(db);
    expect(after.title, 'Untouched title');
    expect(after.body, 'Untouched body');
    // The autosave wrote the slider's and the icon's display defaults; the
    // entry was opened without either, so Cancel clears them again.
    expect(after.mood, isNull);
    expect(after.weatherIcon, isNull);

    await disposeSearchPage(tester);
  });

  testWidgets('an autosave stays local; closing publishes it', (tester) async {
    final remote = InMemorySyncRepository();
    final db = await pumpSearchPage(tester, entries: _seed, remote: remote);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Autosaved, then saved');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect((await _readEntry(db)).title, 'Autosaved, then saved');
    expect(
      await remote.getDocument(FirestoreCollections.journalEntries, _entryId),
      isNull,
      reason: 'an autosave must not upload',
    );

    await tester.tap(find.text('Save'));
    await settle(tester);

    final published = await remote.getDocument(
      FirestoreCollections.journalEntries,
      _entryId,
    );
    expect(published?['title'], 'Autosaved, then saved');

    await disposeSearchPage(tester);
  });

  testWidgets('Escape keeps what was typed', (tester) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Typed then escaped');
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('Journal entry'), findsNothing);
    expect((await _readEntry(db)).title, 'Typed then escaped');

    await disposeSearchPage(tester);
  });

  testWidgets('Enter in the body starts a new line and continues a list', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    final body = _titleField().at(1);
    await tester.tap(body);
    await settle(tester);
    await tester.enterText(body, '- item one');
    await settle(tester);
    // The key itself no longer saves and closes...
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('Journal entry'), findsOneWidget);
    // ...and the newline the platform then inserts continues the list.
    final controller = tester.widget<EditableText>(body).controller;
    await tester.enterText(body, '${controller.text}\n');
    await settle(tester);

    expect(controller.text, '- item one\n- ');

    await disposeSearchPage(tester);
  });

  // The barrier is the one dismissal that is not a decision: a mis-click
  // outside the dialog must not cost the paragraph that was just typed.
  testWidgets('a click on the barrier still saves', (tester) async {
    final db = await pumpSearchPage(tester, entries: _seed);
    await _openEntryDialog(tester);

    await tester.enterText(_titleField().first, 'Typed then clicked away');
    await settle(tester);
    await tester.tapAt(const Offset(4, 4));
    await settle(tester);

    expect(find.text('Journal entry'), findsNothing);
    expect((await _readEntry(db)).title, 'Typed then clicked away');

    await disposeSearchPage(tester);
  });
}

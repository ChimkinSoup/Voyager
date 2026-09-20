// The Search page's dream scope, driven through the real page: the `/dream`
// handoff, what the scope filters, and the popup the dream rows open — which
// has to reach the notepad and the body, and write both to SQLite.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';

import 'support/search_page_harness.dart';

const _dreamId = 'search-dream';

List<JournalEntry> _journalSeed(DateTime now) => [
  JournalEntry(
    id: 'journal-row',
    journalId: searchHarnessJournalId,
    title: 'A waking entry',
    body: 'nothing about flying here',
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  ),
];

List<DreamEntry> _dreamSeed(DateTime now) => [
  DreamEntry(
    id: _dreamId,
    title: 'Flying over water',
    body: 'I was above the harbour',
    notes: 'woke up at 4am',
    entryDate: now,
    createdAt: now,
    updatedAt: now,
    version: 2,
  ),
  DreamEntry(
    id: 'other-dream',
    title: 'Locked door',
    body: 'a corridor with no end',
    entryDate: now.subtract(const Duration(days: 1)),
    createdAt: now,
    updatedAt: now,
  ),
];

Future<DreamEntry> _readDream(AppDatabase db) async {
  final entry = await DriftDreamRepository(db).getEntry(_dreamId);
  return entry!;
}

/// The page's query field — the only editable outside a dialog.
Finder _queryField() => find.byType(EditableText).first;

/// The dream popup is as tall as the journal one (a 480px body) and the
/// scratchpad sits in its bottom-right corner, so the default 800x600 test
/// surface leaves the note off-screen and untappable.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _enterDreamScope(WidgetTester tester, String text) async {
  await tester.enterText(_queryField(), text);
  await settle(tester);
}

void main() {
  testWidgets('/dream swaps the command for the scope chip', (tester) async {
    await pumpSearchPage(tester, entries: _journalSeed, dreams: _dreamSeed);

    await _enterDreamScope(tester, '/dream');

    // The command itself must not be left in the field — the chip is what
    // stands in its place.
    expect(find.text('Dream journals'), findsOneWidget);
    expect(tester.widget<EditableText>(_queryField()).controller.text, '');
    // Journal rows are gone; the scope replaced them rather than adding to
    // them.
    expect(find.text('A waking entry'), findsNothing);
    expect(find.text('Flying over water'), findsOneWidget);
    expect(find.text('Locked door'), findsOneWidget);

    await disposeSearchPage(tester);
  });

  testWidgets('/dream carries a trailing query into the scope', (tester) async {
    await pumpSearchPage(tester, entries: _journalSeed, dreams: _dreamSeed);

    await _enterDreamScope(tester, '/dream flying');

    expect(find.text('Dream journals'), findsOneWidget);
    expect(
      tester.widget<EditableText>(_queryField()).controller.text,
      'flying',
    );
    expect(find.text('Flying over water'), findsOneWidget);
    expect(find.text('Locked door'), findsNothing);

    await disposeSearchPage(tester);
  });

  testWidgets('/dreamscape is an ordinary query', (tester) async {
    await pumpSearchPage(tester, entries: _journalSeed, dreams: _dreamSeed);

    await _enterDreamScope(tester, '/dreamscape');

    expect(find.text('Dream journals'), findsNothing);
    expect(
      tester.widget<EditableText>(_queryField()).controller.text,
      '/dreamscape',
    );

    await disposeSearchPage(tester);
  });

  testWidgets('Escape and Backspace leave the scope', (tester) async {
    await pumpSearchPage(tester, entries: _journalSeed, dreams: _dreamSeed);

    await _enterDreamScope(tester, '/dream flying');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('Dream journals'), findsNothing);
    expect(find.text('A waking entry'), findsOneWidget);

    // Backspace on an empty query is the other way out: the chip is the only
    // thing left to delete at that point.
    await _enterDreamScope(tester, '/dream');
    expect(find.text('Dream journals'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);

    expect(find.text('Dream journals'), findsNothing);
    expect(find.text('A waking entry'), findsOneWidget);

    await disposeSearchPage(tester);
  });

  testWidgets('the notepad matches, and a query the body misses still hits', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: _journalSeed, dreams: _dreamSeed);

    await _enterDreamScope(tester, '/dream 4am');

    expect(find.text('Flying over water'), findsOneWidget);
    expect(find.text('Locked door'), findsNothing);

    await disposeSearchPage(tester);
  });

  testWidgets('a dream popup edits the body and the notepad', (tester) async {
    _useTallWindow(tester);
    final db = await pumpSearchPage(
      tester,
      entries: _journalSeed,
      dreams: _dreamSeed,
    );
    final before = await _readDream(db);

    await _enterDreamScope(tester, '/dream flying');
    await tester.tap(find.text('Flying over water'));
    await settle(tester);
    expect(find.text('Dream'), findsOneWidget);

    final dialogFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(EditableText),
    );
    // Title, then body: the scratchpad is collapsed to its corner sliver until
    // it is tapped, so its field is not in the tree yet.
    await tester.enterText(dialogFields.at(0), 'Flying, revised');
    await settle(tester);
    await tester.enterText(dialogFields.at(1), 'I was above the bridge');
    await settle(tester);

    await tester.tap(find.byType(DreamStickyNote));
    await settle(tester);
    // The note's own field, now the last editable in the dialog.
    await tester.enterText(dialogFields.last, 'woke up at 5am');
    await settle(tester);

    await tester.tap(find.text('Save'));
    await settle(tester);

    final after = await _readDream(db);
    expect(after.title, 'Flying, revised');
    expect(after.body, 'I was above the bridge');
    expect(after.notes, 'woke up at 5am');
    expect(
      after.version,
      greaterThan(before.version),
      reason: 'the published rewrite has to outrank the row it replaced',
    );

    await disposeSearchPage(tester);
  });

  testWidgets('Close discards what the dream popup was given', (tester) async {
    _useTallWindow(tester);
    final db = await pumpSearchPage(
      tester,
      entries: _journalSeed,
      dreams: _dreamSeed,
    );
    final before = await _readDream(db);

    await _enterDreamScope(tester, '/dream flying');
    await tester.tap(find.text('Flying over water'));
    await settle(tester);

    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(EditableText),
          )
          .first,
      'Typed then thrown away',
    );
    await settle(tester);
    await tester.tap(find.text('Close'));
    await settle(tester);

    final after = await _readDream(db);
    expect(after.title, before.title);
    expect(after.version, before.version);
    expect(after.updatedAt, before.updatedAt);

    await disposeSearchPage(tester);
  });

  testWidgets('with Vim on, Escape belongs to Vim and the scope survives', (
    tester,
  ) async {
    await pumpSearchPage(
      tester,
      entries: _journalSeed,
      dreams: _dreamSeed,
      vimEnabled: true,
    );

    await _enterDreamScope(tester, '/dream flying');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Escape left Insert; it did not take the chip with it. This handler is
    // installed in the focus node's slot, which runs before the Vim layer
    // above the field, so claiming Escape here used to swallow it whole.
    expect(find.text('Dream journals'), findsOneWidget);
    expect(
      tester.widget<EditableText>(_queryField()).controller.text,
      'flying',
    );

    // And Vim really did get it: `x` is a delete in Normal mode, not a
    // character typed into the query.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await settle(tester);
    expect(tester.widget<EditableText>(_queryField()).controller.text, 'flyin');

    // Backspace on an empty query stays the Vim user's way out — Normal
    // mode's `h` has nothing to move over there.
    await tester.enterText(_queryField(), '');
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);
    expect(find.text('Dream journals'), findsNothing);

    await disposeSearchPage(tester);
  });

  testWidgets('the popup scratchpad indents with Tab and eats a bare marker', (
    tester,
  ) async {
    _useTallWindow(tester);
    await pumpSearchPage(tester, entries: _journalSeed, dreams: _dreamSeed);

    await _enterDreamScope(tester, '/dream flying');
    await tester.tap(find.text('Flying over water'));
    await settle(tester);
    await tester.tap(find.byType(DreamStickyNote));
    await settle(tester);

    final note = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(EditableText),
        )
        .last;
    final controller = tester.widget<EditableText>(note).controller;
    final noteFocus = tester.widget<EditableText>(note).focusNode;

    // Tab indents the bullet rather than walking focus out of the note.
    controller.value = const TextEditingValue(
      text: '- milk',
      selection: TextSelection.collapsed(offset: 6),
    );
    noteFocus.requestFocus();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    expect(controller.text, '$listIndentUnit- milk');
    expect(noteFocus.hasFocus, isTrue, reason: 'Tab must not leave the note');

    // Shift+Tab takes the indent back.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(controller.text, '- milk');

    // Backspace behind a bare marker removes the whole marker, not one of
    // its characters.
    controller.value = const TextEditingValue(
      text: '- ',
      selection: TextSelection.collapsed(offset: 2),
    );
    noteFocus.requestFocus();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);
    expect(controller.text, '');

    await disposeSearchPage(tester);
  });
}

// Vim's `/` prompt inside the Search result popup.
//
// Both of the popup's fields claim Enter in their own focus node to save and
// close, and a field's node sees a key before the Vim layer above it — so the
// Enter that should have run the search closed the dialog instead.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/search_page_harness.dart';

const _entryId = 'search-entry';

List<JournalEntry> _seed(DateTime now) => [
  JournalEntry(
    id: _entryId,
    journalId: searchHarnessJournalId,
    title: 'Some title here',
    body: 'Untouched body\nsecond line',
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  ),
];

Finder _field(int index) => find
    .descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(EditableText),
    )
    .at(index);

Future<void> _type(WidgetTester tester, String text) async {
  for (final ch in text.split('')) {
    final key = ch == '/'
        ? LogicalKeyboardKey.slash
        : LogicalKeyboardKey.knownLogicalKeys.firstWhere(
            (k) => k.keyLabel.toLowerCase() == ch,
          );
    await tester.sendKeyEvent(key, character: ch);
  }
  await settle(tester);
}

void main() {
  for (final (name, index, word, offset) in [
    ('title', 0, 'here', 11),
    ('body', 1, 'body', 10),
  ]) {
    testWidgets('Enter runs a / search in the $name instead of saving', (
      tester,
    ) async {
      await pumpSearchPage(tester, entries: _seed, vimEnabled: true);
      await tester.tap(find.text('Some title here'));
      await settle(tester);

      await tester.tap(_field(index));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      final controller = tester.widget<EditableText>(_field(index)).controller;
      controller.selection = const TextSelection.collapsed(offset: 0);
      await settle(tester);

      await _type(tester, '/$word');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(find.text('Journal entry'), findsOneWidget);
      expect(controller.selection.baseOffset, offset);

      await disposeSearchPage(tester);
    });
  }

  testWidgets('Enter in Normal mode moves down a line in the body', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: _seed, vimEnabled: true);
    await tester.tap(find.text('Some title here'));
    await settle(tester);
    await tester.tap(_field(1));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    final controller = tester.widget<EditableText>(_field(1)).controller;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.text('Journal entry'), findsOneWidget);
    expect(controller.selection.baseOffset, 'Untouched body\n'.length);

    await disposeSearchPage(tester);
  });

  testWidgets('Enter in Normal mode in the one-line title still saves', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: _seed, vimEnabled: true);
    await tester.tap(find.text('Some title here'));
    await settle(tester);
    await tester.tap(_field(0));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.text('Journal entry'), findsNothing);

    await disposeSearchPage(tester);
  });

  testWidgets('Tab in a / search moves focus instead of typing a tab', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: _seed, vimEnabled: true);
    await tester.tap(find.text('Some title here'));
    await settle(tester);
    await tester.tap(_field(0));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await _type(tester, '/so');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);

    expect(tester.widget<EditableText>(_field(1)).focusNode.hasFocus, isTrue);

    await disposeSearchPage(tester);
  });
}

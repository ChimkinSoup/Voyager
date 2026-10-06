// The Search page says why it is empty instead of showing a blank page
// (BUG-087), and its query field takes the keyboard on arrival and on Ctrl+F
// (BUG-088).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/search_page_harness.dart';

List<JournalEntry> Function(DateTime) _entries(List<String> bodies) =>
    (now) => [
      for (var i = 0; i < bodies.length; i++)
        JournalEntry(
          id: 'e$i',
          journalId: searchHarnessJournalId,
          title: 'Entry $i',
          body: bodies[i],
          entryDate: now,
          timestamp: now,
          createdAt: now,
          updatedAt: now,
        ),
    ];

EditableText _field(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).first);

void main() {
  testWidgets('an account with no entries gets a first-run line', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: (_) => []);
    expect(find.textContaining('No journal entries yet'), findsOneWidget);
    await disposeSearchPage(tester);
  });

  testWidgets('a query that matches nothing says so', (tester) async {
    await pumpSearchPage(tester, entries: _entries(['apples', 'pears']));
    await tester.enterText(find.byType(EditableText).first, 'qqqzzz');
    await settle(tester);
    expect(find.text('No entries match “qqqzzz”'), findsOneWidget);
    await disposeSearchPage(tester);
  });

  testWidgets('a query shows how many entries it matched', (tester) async {
    await pumpSearchPage(
      tester,
      entries: _entries(['red apples', 'green apples', 'pears']),
    );
    expect(find.textContaining('match'), findsNothing);

    await tester.enterText(find.byType(EditableText).first, 'apples');
    await settle(tester);
    expect(find.text('2 matches'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).first, 'pears');
    await settle(tester);
    expect(find.text('1 match'), findsOneWidget);
    await disposeSearchPage(tester);
  });

  testWidgets('typing or clearing a query keeps the same results list', (
    tester,
  ) async {
    await pumpSearchPage(tester, entries: _entries(['red apples', 'pears']));
    Element list() => tester.element(find.byType(KeepAliveScrollList));
    final before = list();

    await tester.enterText(find.byType(EditableText).first, 'apples');
    await settle(tester);
    expect(find.text('1 match'), findsOneWidget);
    expect(identical(list(), before), isTrue);

    await tester.enterText(find.byType(EditableText).first, '');
    await settle(tester);
    expect(identical(list(), before), isTrue);
    await disposeSearchPage(tester);
  });

  testWidgets('the query field is focused on arrival', (tester) async {
    await pumpSearchPage(tester, entries: _entries(['apples']));
    expect(_field(tester).focusNode.hasFocus, isTrue);
    await disposeSearchPage(tester);
  });

  testWidgets('Ctrl+F focuses the query and selects it', (tester) async {
    await pumpSearchPage(tester, entries: _entries(['apples']));
    await tester.enterText(find.byType(EditableText).first, 'apples');
    await settle(tester);
    _field(tester).focusNode.unfocus();
    await tester.pump();
    expect(_field(tester).focusNode.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final field = _field(tester);
    expect(field.focusNode.hasFocus, isTrue);
    expect(
      field.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 6),
    );
    await disposeSearchPage(tester);
  });
}

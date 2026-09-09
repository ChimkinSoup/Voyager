// Regression coverage for the journal body losing every key its own handler
// owns — Tab indent, smart Backspace, the `#tag` completion popup.
//
// The body field is re-inflated once during a page load: `_withImages` hands
// back the bare field while there is no entry yet, then wraps it in a
// MediaPasteScope/Stack the moment the entry arrives. Both shapes carry the
// same FocusNode, and the outgoing TagSuggestionPortal — which owns
// `focusNode.onKeyEvent` — is not unmounted until after its replacement has
// installed a handler, so an unconditional clear in its dispose left the
// field with no key handler at all.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/journal_page_harness.dart';

Future<TextEditingController> _pumpBody(
  WidgetTester tester,
  String body,
) async {
  await pumpJournalPage(
    tester,
    seedEntries: (now) => [
      JournalEntry(
        id: 'harness-entry',
        journalId: journalHarnessId,
        title: 'Seeded entry',
        body: body,
        entryDate: now,
        timestamp: now,
        createdAt: now,
        updatedAt: now,
      ),
    ],
  );
  final field = find.byType(TagHighlightedTextField);
  expect(field, findsOneWidget);
  await tester.tap(field);
  await tester.pump();
  return tester.widget<TagHighlightedTextField>(field).controller;
}

void main() {
  testWidgets('Tab indents the bullet the caret is on', (tester) async {
    final controller = await _pumpBody(tester, '- item');
    controller.selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, '  - item');
    expect(controller.selection.baseOffset, 8);

    await disposeJournalPage(tester);
  });

  testWidgets('Shift+Tab outdents it again', (tester) async {
    final controller = await _pumpBody(tester, '  - item');
    controller.selection = const TextSelection.collapsed(offset: 8);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.text, '- item');

    await disposeJournalPage(tester);
  });

  testWidgets('Backspace after a bullet marker removes the whole marker', (
    tester,
  ) async {
    final controller = await _pumpBody(tester, '- ');
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(controller.text, '');

    await disposeJournalPage(tester);
  });

  testWidgets('the body keeps its field when the first entry appears', (
    tester,
  ) async {
    await pumpJournalPage(tester, seedEntries: (now) => []);

    // The wrappers are mounted with no owner rather than left off, so the
    // field below them is not re-inflated the moment there is an entry.
    expect(find.byType(MediaPasteScope), findsOneWidget);
    final bodyEditable = find.descendant(
      of: find.byType(TagHighlightedTextField),
      matching: find.byType(EditableText),
    );
    final before = tester.state<EditableTextState>(bodyEditable);

    final newEntry = find.text('New entry');
    expect(newEntry, findsWidgets);
    await tester.tap(newEntry.first, warnIfMissed: false);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(
      tester.state<EditableTextState>(bodyEditable),
      same(before),
      reason: 'the writing area was rebuilt from scratch',
    );

    await disposeJournalPage(tester);
  });
}

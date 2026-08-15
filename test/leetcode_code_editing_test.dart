import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

TextEditingValue addChar(TextEditingValue v, String char) {
  final s = v.selection;
  return TextEditingValue(
    text: v.text.replaceRange(s.start, s.end, char),
    selection: TextSelection.collapsed(
      offset: s.start + char.length,
      affinity: TextAffinity.downstream,
    ),
  );
}

TextEditingValue backspace(TextEditingValue v) {
  final s = v.selection;
  if (!s.isCollapsed || s.start == 0) return v;
  return TextEditingValue(
    text: v.text.replaceRange(s.start - 1, s.start, ''),
    selection: TextSelection.collapsed(
      offset: s.start - 1,
      affinity: TextAffinity.downstream,
    ),
  );
}

String _closerFor(String opener) =>
    const {'(': ')', '[': ']', '{': '}'}[opener] ?? opener;

void main() {
  group('applyLeetCodeCodeEdits', () {
    test('closes a blank indented line to the matching brace indent', () {
      const current = TextEditingValue(
        text: '{\n    \n',
        selection: TextSelection.collapsed(offset: 6),
      );
      final incoming = addChar(current, '}');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result!.text, '{\n}\n');
      expect(result.selection.baseOffset, 3);
    });

    test('never swallows a } that is on another line', () {
      // The brace on the line below closes an outer block. Typing one here
      // adds a brace; it must not consume that one.
      const current = TextEditingValue(
        text: '{\n    \n}',
        selection: TextSelection.collapsed(offset: 6),
      );
      final incoming = addChar(current, '}');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result!.text, '{\n}\n}');
      expect(result.selection.baseOffset, 3);
    });

    test('skips an auto-paired closer on the same line after outdent', () {
      const current = TextEditingValue(
        text: '{\n  }',
        selection: TextSelection.collapsed(offset: 4),
      );
      final incoming = addChar(current, '}');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result!.text, '{\n}');
      expect(result.selection.baseOffset, 3);
    });

    test('skips a paired closer mid-line without duplicating', () {
      const current = TextEditingValue(
        text: '{}',
        selection: TextSelection.collapsed(offset: 1),
      );
      final incoming = addChar(current, '}');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result!.text, '{}');
      expect(result.selection.baseOffset, 2);
    });

    test('splits Enter between paired braces', () {
      const current = TextEditingValue(
        text: '{}',
        selection: TextSelection.collapsed(offset: 1),
      );
      final incoming = addChar(current, '\n');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result!.text, '{\n  \n}');
      expect(result.selection.baseOffset, 4);
    });

    test('splits Enter between paired brackets and parentheses', () {
      for (final pair in ['[]', '()']) {
        final current = TextEditingValue(
          text: '  $pair',
          selection: const TextSelection.collapsed(offset: 3),
        );
        final result = applyLeetCodeCodeEdits(
          current: current,
          incoming: addChar(current, '\n'),
          tabSpaces: 2,
        );
        expect(result!.text, '  ${pair[0]}\n    \n  ${pair[1]}');
        expect(result.selection.baseOffset, 8);
      }
    });

    test('does not split Enter inside a quote pair', () {
      const current = TextEditingValue(
        text: '""',
        selection: TextSelection.collapsed(offset: 1),
      );
      final incoming = addChar(current, '\n');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result, isNull);
    });

    test('steps over a closer already at the caret instead of doubling it', () {
      for (final pair in ['()', '[]', '""', "''", '``']) {
        final current = TextEditingValue(
          text: 'x$pair',
          selection: const TextSelection.collapsed(offset: 2),
        );
        final result = applyLeetCodeCodeEdits(
          current: current,
          incoming: addChar(current, pair[1]),
          tabSpaces: 2,
        );
        expect(result!.text, 'x$pair', reason: pair);
        expect(result.selection.baseOffset, 3, reason: pair);
      }
    });

    test('typing a closer with no pair at the caret inserts it', () {
      const current = TextEditingValue(
        text: 'foo',
        selection: TextSelection.collapsed(offset: 3),
      );
      final incoming = addChar(current, ')');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result, isNull);
    });

    test('backspacing an opener takes its empty closer with it', () {
      const current = TextEditingValue(
        text: 'f()',
        selection: TextSelection.collapsed(offset: 2),
      );
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: backspace(current),
        tabSpaces: 2,
      );
      expect(result!.text, 'f');
      expect(result.selection.baseOffset, 1);
    });

    test('backspacing an opener that holds text leaves the closer', () {
      const current = TextEditingValue(
        text: 'f(x)',
        selection: TextSelection.collapsed(offset: 2),
      );
      final incoming = backspace(current);
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result, isNull);
    });

    test('does not auto-close directly before a word character', () {
      for (final opener in ['(', '[', '{', '"', "'", '`']) {
        const current = TextEditingValue(
          text: 'foobar',
          selection: TextSelection.collapsed(offset: 3),
        );
        final incoming = addChar(current, opener);
        final result = applyLeetCodeCodeEdits(
          current: current,
          incoming: incoming,
          tabSpaces: 2,
        );
        // Non-null so the auto-close modifier is skipped, but the value is
        // the plain insert.
        expect(result, isNotNull, reason: opener);
        expect(result!.text, 'foo${opener}bar', reason: opener);
        expect(result.selection.baseOffset, 4, reason: opener);
      }
    });

    test('auto-closes before whitespace, punctuation and end of text', () {
      for (final rest in ['', ' x', ');', ']']) {
        final current = TextEditingValue(
          text: 'foo$rest',
          selection: const TextSelection.collapsed(offset: 3),
        );
        final result = applyLeetCodeCodeEdits(
          current: current,
          incoming: addChar(current, '('),
          tabSpaces: 2,
        );
        // Handed back to the modifier, which is what inserts the pair.
        expect(result, isNull, reason: 'rest="$rest"');
      }
    });

    test('a quote after a word character is an apostrophe, not a pair', () {
      const current = TextEditingValue(
        text: "don t",
        selection: TextSelection.collapsed(offset: 3),
      );
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: addChar(current, "'"),
        tabSpaces: 2,
      );
      expect(result, isNotNull);
      expect(result!.text, "don' t");
      expect(result.selection.baseOffset, 4);
    });

    test('a bracket after a word character still auto-closes', () {
      const current = TextEditingValue(
        text: 'foo ',
        selection: TextSelection.collapsed(offset: 3),
      );
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: addChar(current, '('),
        tabSpaces: 2,
      );
      expect(result, isNull);
    });

    test('typing a pair character over a selection wraps it', () {
      for (final opener in ['(', '[', '{', '"', "'", '`']) {
        const current = TextEditingValue(
          text: 'a bcd e',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        );
        final incoming = TextEditingValue(
          text: 'a $opener e',
          selection: const TextSelection.collapsed(offset: 3),
        );
        final result = applyLeetCodeCodeEdits(
          current: current,
          incoming: incoming,
          tabSpaces: 2,
        );
        expect(result, isNotNull, reason: opener);
        expect(result!.text, 'a ${opener}bcd${_closerFor(opener)} e',
            reason: opener);
        // The wrapped text stays selected, so a second keystroke nests.
        expect(result.selection.start, 3, reason: opener);
        expect(result.selection.end, 6, reason: opener);
      }
    });

    test('wrapping keeps a backwards selection backwards', () {
      const current = TextEditingValue(
        text: 'a bcd e',
        selection: TextSelection(baseOffset: 5, extentOffset: 2),
      );
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: const TextEditingValue(
          text: 'a ( e',
          selection: TextSelection.collapsed(offset: 3),
        ),
        tabSpaces: 2,
      );
      expect(result!.text, 'a (bcd) e');
      expect(result.selection.baseOffset, 6);
      expect(result.selection.extentOffset, 3);
    });

    test('typing an ordinary character over a selection replaces it', () {
      const current = TextEditingValue(
        text: 'a bcd e',
        selection: TextSelection(baseOffset: 2, extentOffset: 5),
      );
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: const TextEditingValue(
          text: 'a z e',
          selection: TextSelection.collapsed(offset: 3),
        ),
        tabSpaces: 2,
      );
      expect(result, isNull);
    });

    test('leaves ordinary characters alone', () {
      const current = TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 2),
      );
      final incoming = addChar(current, 'c');
      final result = applyLeetCodeCodeEdits(
        current: current,
        incoming: incoming,
        tabSpaces: 2,
      );
      expect(result, isNull);
    });
  });

  group('LeetCodeCodeController', () {
    test('typing } on an indented blank line inserts the brace once', () {
      final c = LeetCodeCodeController(text: '{\n    \n}');
      c.selection = const TextSelection.collapsed(offset: 6);
      c.value = addChar(c.value, '}');
      // One brace typed, one brace added — outdented onto the caret's line,
      // with the pre-existing closer on the line below left where it was.
      expect(c.text, '{\n}\n}');
      expect(c.selection.baseOffset, 3);
      c.dispose();
    });

    test('brace then Enter opens the block, then } adds its own closer', () {
      final c = LeetCodeCodeController();
      c.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
      c.value = addChar(c.value, '{');
      expect(c.text, '{}');
      c.value = addChar(c.value, '\n');
      expect(c.text, '{\n  \n}');
      // The closer on the line below is the one this block already has. A `}`
      // typed on the blank line is a second brace, outdented to match.
      c.value = addChar(c.value, '}');
      expect(c.text, '{\n}\n}');
      expect(c.selection.baseOffset, 3);
      c.dispose();
    });

    test('} on a blank line lands with the matching opener indent', () {
      // The caret line is blank; the innermost unclosed `{` is the one on the
      // `if` line, so the brace outdents to that line's indent.
      final c = LeetCodeCodeController(text: 'a {\n  if {\n    x;\n    ');
      c.selection = const TextSelection.collapsed(offset: 22);
      c.value = addChar(c.value, '}');
      expect(c.text, 'a {\n  if {\n    x;\n  }');
      expect(c.selection.baseOffset, 21);
      c.dispose();
    });

    test('deleting an auto-inserted pair removes both halves', () {
      final c = LeetCodeCodeController(text: 'f');
      c.selection = const TextSelection.collapsed(offset: 1);
      c.value = addChar(c.value, '(');
      expect(c.text, 'f()');
      expect(c.selection.baseOffset, 2);
      c.value = backspace(c.value);
      expect(c.text, 'f');
      expect(c.selection.baseOffset, 1);
      c.dispose();
    });

    test('an apostrophe mid-word stays a single quote', () {
      final c = LeetCodeCodeController(text: '# dont stop');
      c.selection = const TextSelection.collapsed(offset: 5);
      c.value = addChar(c.value, "'");
      expect(c.text, "# don't stop");
      expect(c.selection.baseOffset, 6);
      c.dispose();
    });

    test('an opening quote at end of line still pairs', () {
      final c = LeetCodeCodeController(text: 'x = ');
      c.selection = const TextSelection.collapsed(offset: 4);
      c.value = addChar(c.value, "'");
      expect(c.text, "x = ''");
      expect(c.selection.baseOffset, 5);
      c.dispose();
    });

    test('a bracket typed against following text does not pair', () {
      final c = LeetCodeCodeController(text: 'foobar');
      c.selection = const TextSelection.collapsed(offset: 3);
      c.value = addChar(c.value, '(');
      expect(c.text, 'foo(bar');
      expect(c.selection.baseOffset, 4);
      c.dispose();
    });

    test('a bracket typed over a selection wraps it, twice over', () {
      final c = LeetCodeCodeController(text: 'call arg here');
      c.selection = const TextSelection(baseOffset: 5, extentOffset: 8);
      c.value = const TextEditingValue(
        text: 'call ( here',
        selection: TextSelection.collapsed(offset: 6),
      );
      expect(c.text, 'call (arg) here');
      expect(c.selection.start, 6);
      expect(c.selection.end, 9);
      // The selection survived on `arg`, so a quote nests inside the parens.
      c.value = const TextEditingValue(
        text: 'call (") here',
        selection: TextSelection.collapsed(offset: 7),
      );
      expect(c.text, 'call ("arg") here');
      c.dispose();
    });

    test('carriage returns never reach the buffer', () {
      final c = LeetCodeCodeController(text: 'a {\r\n  b;\r\n}');
      expect(c.text, 'a {\n  b;\n}');
      // A CRLF paste at the caret is normalized too, caret included.
      c.selection = const TextSelection.collapsed(offset: 10);
      c.value = const TextEditingValue(
        text: 'a {\n  b;\n}\r\nc\r\n',
        selection: TextSelection.collapsed(offset: 15),
      );
      expect(c.text, 'a {\n  b;\n}\nc\n');
      expect(c.selection.baseOffset, 13);
      c.dispose();
    });

    test('type then delete at end of line keeps caret on that line', () {
      final c = LeetCodeCodeController(text: 'abc\ndef');
      c.selection = const TextSelection.collapsed(offset: 3);
      c.value = addChar(c.value, 'X');
      c.value = backspace(c.value);
      expect(c.text, 'abc\ndef');
      expect(c.selection.baseOffset, 3);
      expect(c.selection.affinity, TextAffinity.upstream);
      // Another backspace must delete 'c', not the newline.
      c.value = backspace(c.value);
      expect(c.text, 'ab\ndef');
      c.dispose();
    });

    test('deleting } removes the brace, not the following blank line', () {
      final c = LeetCodeCodeController(text: '{\n}\n');
      c.selection = const TextSelection.collapsed(
        offset: 3,
        affinity: TextAffinity.upstream,
      );
      c.value = backspace(c.value);
      expect(c.text, '{\n\n');
      expect(c.selection.baseOffset, 2);
      c.dispose();
    });
  });

  group('code field clicking', () {
    testWidgets('backspace at a clicked end-of-line deletes that character', (
      tester,
    ) async {
      // Pasted from a Windows editor, so every break arrived as `\r\n`. A
      // click past the right edge of a line used to land between the `\r` and
      // the `\n`, and backspace — which deletes whole grapheme clusters —
      // then took the break instead of the brace.
      final controller = LeetCodeCodeController(
        text: 'class A {\r\n    int x;\r\n}',
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                width: 600,
                child: LeetCodeCodeInput(
                  controller: controller,
                  language: 'java',
                  onLanguageChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editable = tester.state<EditableTextState>(
        find.byWidgetPredicate(
          (w) => w is EditableText && w.controller == controller,
        ),
      );
      final render = editable.renderEditable;
      final endOfFirstLine = render.getLocalRectForCaret(
        const TextPosition(offset: 9),
      );
      await tester.tapAt(
        render.localToGlobal(endOfFirstLine.center) + const Offset(200, 0),
      );
      await tester.pumpAndSettle();
      expect(controller.selection.baseOffset, 9);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(controller.text, 'class A \n    int x;\n}');

      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a click in the empty space below the code focuses it', (
      tester,
    ) async {
      // The box is 160px tall from empty; the field inside is only as tall as
      // the lines it holds. Everything below the last line looks like part of
      // the field, so it has to behave like it.
      final controller = LeetCodeCodeController(text: 'class A {\n}');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: VimEnabledScope(
            enabled: false,
            child: Scaffold(
              body: SizedBox(
                width: 600,
                child: LeetCodeCodeInput(
                  controller: controller,
                  language: 'java',
                  onLanguageChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editable = find.byWidgetPredicate(
        (w) => w is EditableText && w.controller == controller,
      );
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isFalse);

      // Inside the box the user sees, below the last line of code — the band
      // that has no field under it.
      final field = tester.getRect(editable);
      final box = tester.getRect(find.byType(VoyagerScrollView).first);
      final belowLastLine = Offset(field.center.dx, field.bottom + 40);
      expect(box.contains(belowLastLine), isTrue);
      expect(
        field.contains(belowLastLine),
        isFalse,
        reason: 'the point under test must be outside the field itself',
      );

      await tester.tapAt(belowLastLine);
      await tester.pumpAndSettle();

      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
      expect(controller.selection.baseOffset, controller.text.length);

      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('code field Tab', () {
    testWidgets('Tab inserts spaces instead of moving focus', (tester) async {
      final controller = LeetCodeCodeController(text: 'abc');
      addTearDown(controller.dispose);
      final titleFocus = FocusNode();
      addTearDown(titleFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: Column(
                children: [
                  TextField(focusNode: titleFocus),
                  LeetCodeCodeInput(
                    controller: controller,
                    language: 'python',
                    onLanguageChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final codeEditable = find.byWidgetPredicate(
        (widget) => widget is EditableText && widget.controller == controller,
      );
      await tester.tap(codeEditable);
      await tester.pumpAndSettle();
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(controller.text, startsWith('  '));
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>(),
        isNotNull,
        reason: 'Tab must stay in the code box',
      );
      expect(titleFocus.hasFocus, isFalse);

      await tester.pump(const Duration(seconds: 1));
    });
  });
}

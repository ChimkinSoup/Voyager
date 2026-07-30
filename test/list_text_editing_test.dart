import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/list_text_editing.dart';

/// Simulates the user typing at the end of [previousText] by appending
/// [typed], then runs [applyListEditing] the way a real `onChanged` handler
/// would (controller already holds the post-keystroke value).
TextEditingController _typeAtEnd(String previousText, String typed) {
  final controller = TextEditingController(text: previousText + typed)
    ..selection = TextSelection.collapsed(offset: previousText.length + typed.length);
  applyListEditing(controller: controller, previousText: previousText);
  return controller;
}

void main() {
  group('Enter-continuation', () {
    test('continues a dash bullet', () {
      final c = _typeAtEnd('- foo', '\n');
      expect(c.text, '- foo\n- ');
      expect(c.selection, TextSelection.collapsed(offset: c.text.length));
    });

    test('continues a star bullet', () {
      final c = _typeAtEnd('* foo', '\n');
      expect(c.text, '* foo\n* ');
    });

    test('continues a numbered item, incrementing the number', () {
      final c = _typeAtEnd('1. foo', '\n');
      expect(c.text, '1. foo\n2. ');
    });

    test('preserves indentation on continuation', () {
      final c = _typeAtEnd('  - foo', '\n');
      expect(c.text, '  - foo\n  - ');
    });

    test('does not continue a plain line', () {
      final c = _typeAtEnd('just text', '\n');
      expect(c.text, 'just text\n');
    });

    test('does not trigger on non-newline typing', () {
      final c = _typeAtEnd('- foo', 'x');
      expect(c.text, '- foox');
    });

    test('clean exit: Enter on an empty bullet clears the marker', () {
      final c = _typeAtEnd('- ', '\n');
      expect(c.text, '');
      expect(c.selection, const TextSelection.collapsed(offset: 0));
    });

    test('clean exit: Enter on an empty numbered item clears the marker', () {
      final c = _typeAtEnd('3. ', '\n');
      expect(c.text, '');
    });

    test('clean exit only strips the empty item, keeps prior lines', () {
      final c = _typeAtEnd('1. a\n2. ', '\n');
      expect(c.text, '1. a\n');
    });
  });

  group('renumbering', () {
    TextEditingController controllerFor(String text, {int? cursor}) {
      final c = TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: cursor ?? text.length);
      return c;
    }

    test('renumbers after a middle item is deleted', () {
      // Simulate deleting "2. b\n" from "1. a\n2. b\n3. c".
      final c = controllerFor('1. a\n3. c');
      applyListEditing(controller: c, previousText: '1. a\n2. b\n3. c');
      expect(c.text, '1. a\n2. c');
    });

    test('renumbers a pasted list with duplicate numbers', () {
      final c = controllerFor('1. one\n1. two\n1. three');
      applyListEditing(controller: c, previousText: '');
      expect(c.text, '1. one\n2. two\n3. three');
    });

    test('blank lines do not break a list block', () {
      final c = controllerFor('1. a\n\n5. b');
      applyListEditing(controller: c, previousText: '1. a\n\n5. b');
      expect(c.text, '1. a\n\n2. b');
    });

    test('prose interrupts a list, starting a fresh anchored block', () {
      final c = controllerFor('1. a\nsome text\n5. b');
      applyListEditing(controller: c, previousText: '1. a\nsome text\n5. b');
      expect(c.text, '1. a\nsome text\n5. b');
    });

    test('a bullet line interrupts a numbered list', () {
      final c = controllerFor('1. a\n- x\n5. b');
      applyListEditing(controller: c, previousText: '1. a\n- x\n5. b');
      expect(c.text, '1. a\n- x\n5. b');
    });

    test('nested indent levels renumber independently', () {
      final c = controllerFor('1. a\n  5. x\n  9. y\n7. b');
      applyListEditing(controller: c, previousText: '1. a\n  5. x\n  9. y\n7. b');
      expect(c.text, '1. a\n  5. x\n  6. y\n2. b');
    });

    test('cursor after the edited number stays with its line', () {
      final text = '1. a\n3. b';
      final c = controllerFor(text, cursor: text.length);
      applyListEditing(controller: c, previousText: text);
      expect(c.text, '1. a\n2. b');
      expect(c.selection.baseOffset, c.text.length);
    });

    test('cursor before a renumbered line is unaffected', () {
      final text = '1. a\n3. b';
      final c = controllerFor(text, cursor: 2); // inside "1. a"
      applyListEditing(controller: c, previousText: text);
      expect(c.text, '1. a\n2. b');
      expect(c.selection.baseOffset, 2);
    });
  });

  group('Tab indent / outdent', () {
    test('indents a bullet line at the cursor', () {
      final c = TextEditingController(text: '- item')
        ..selection = const TextSelection.collapsed(offset: 6);
      final handled = handleListTab(controller: c, outdent: false);
      expect(handled, isTrue);
      expect(c.text, '  - item');
      expect(c.selection, const TextSelection.collapsed(offset: 8));
    });

    test('outdents an indented bullet line', () {
      final c = TextEditingController(text: '  - item')
        ..selection = const TextSelection.collapsed(offset: 8);
      final handled = handleListTab(controller: c, outdent: true);
      expect(handled, isTrue);
      expect(c.text, '- item');
      expect(c.selection, const TextSelection.collapsed(offset: 6));
    });

    test('outdenting a top-level line is a no-op and reports unhandled', () {
      final c = TextEditingController(text: '- item')
        ..selection = const TextSelection.collapsed(offset: 6);
      final handled = handleListTab(controller: c, outdent: true);
      expect(handled, isFalse);
      expect(c.text, '- item');
    });

    test('non-list lines report unhandled so callers keep default Tab behavior', () {
      final c = TextEditingController(text: 'plain text')
        ..selection = const TextSelection.collapsed(offset: 4);
      final handled = handleListTab(controller: c, outdent: false);
      expect(handled, isFalse);
      expect(c.text, 'plain text');
    });

    test('indenting a numbered item renumbers both the old and new blocks', () {
      final text = '1. a\n2. b\n3. c';
      final c = TextEditingController(text: text)
        ..selection = const TextSelection.collapsed(offset: 7); // inside "2. b"
      final handled = handleListTab(controller: c, outdent: false);
      expect(handled, isTrue);
      // "2. b" becomes a nested block of its own (anchors at "2"), and "3. c"
      // moves up to fill the gap left in the top-level block.
      expect(c.text, '1. a\n  2. b\n2. c');
    });

    test('indents every list line in a multi-line selection, skips prose', () {
      final text = '- a\ntext\n- b';
      final c = TextEditingController(text: text)
        ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
      final handled = handleListTab(controller: c, outdent: false);
      expect(handled, isTrue);
      expect(c.text, '  - a\ntext\n  - b');
    });

    test('multi-line paste of list content integrates with renumbering', () {
      final c = TextEditingController(text: '1. existing\n1. pasted a\n1. pasted b')
        ..selection = TextSelection.collapsed(
          offset: '1. existing\n1. pasted a\n1. pasted b'.length,
        );
      applyListEditing(
        controller: c,
        previousText: '1. existing',
      );
      expect(c.text, '1. existing\n2. pasted a\n3. pasted b');
    });
  });

  group('isOnListLine', () {
    test('true when cursor is on a bullet line', () {
      final c = TextEditingController(text: '- item')
        ..selection = const TextSelection.collapsed(offset: 3);
      expect(isOnListLine(c), isTrue);
    });

    test('false on a plain line', () {
      final c = TextEditingController(text: 'plain text')
        ..selection = const TextSelection.collapsed(offset: 3);
      expect(isOnListLine(c), isFalse);
    });

    test('true when cursor is on the second line of a multi-line field', () {
      final c = TextEditingController(text: 'intro\n1. item')
        ..selection = const TextSelection.collapsed(offset: 9);
      expect(isOnListLine(c), isTrue);
    });
  });

  group('smart backspace', () {
    test('removes a whole bullet marker in one keystroke', () {
      final c = TextEditingController(text: '- item')
        ..selection = const TextSelection.collapsed(offset: 2);
      final handled = handleListBackspace(controller: c);
      expect(handled, isTrue);
      expect(c.text, 'item');
      expect(c.selection, const TextSelection.collapsed(offset: 0));
    });

    test('removes a whole numbered marker in one keystroke', () {
      final c = TextEditingController(text: '1. item')
        ..selection = const TextSelection.collapsed(offset: 3);
      final handled = handleListBackspace(controller: c);
      expect(handled, isTrue);
      expect(c.text, 'item');
      expect(c.selection, const TextSelection.collapsed(offset: 0));
    });

    test('removes indent along with the marker', () {
      final c = TextEditingController(text: '  - item')
        ..selection = const TextSelection.collapsed(offset: 4);
      final handled = handleListBackspace(controller: c);
      expect(handled, isTrue);
      expect(c.text, 'item');
      expect(c.selection, const TextSelection.collapsed(offset: 0));
    });

    test('removing a middle marker renumbers the trailing block if still contiguous', () {
      const text = '1. a\n2. b\n3. c';
      final markerEnd = text.indexOf('2. ') + '2. '.length;
      final c = TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: markerEnd);
      final handled = handleListBackspace(controller: c);
      expect(handled, isTrue);
      // "b" is no longer numbered, breaking contiguity, so "3. c" is now a
      // fresh anchored block and keeps its own number.
      expect(c.text, '1. a\nb\n3. c');
    });

    test('does nothing when cursor is not right at the marker boundary', () {
      final c = TextEditingController(text: '- item')
        ..selection = const TextSelection.collapsed(offset: 4);
      final handled = handleListBackspace(controller: c);
      expect(handled, isFalse);
      expect(c.text, '- item');
    });

    test('does nothing on a non-list line', () {
      final c = TextEditingController(text: 'plain text')
        ..selection = const TextSelection.collapsed(offset: 0);
      final handled = handleListBackspace(controller: c);
      expect(handled, isFalse);
      expect(c.text, 'plain text');
    });
  });
}

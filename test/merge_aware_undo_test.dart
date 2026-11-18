// Ctrl+Z in a journal or dream body took out another device's text that had
// just arrived, since the merge was the newest undo step, and the field's next
// save deleted it on every device (BUG-237). The fields that merge remote text
// now undo through [MergeAwareUndoController], which carries each merge into
// the steps it already holds and never makes one a step of its own.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/merge_aware_undo.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

const _pause = Duration(milliseconds: 600);

Future<void> _ctrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  late TextEditingController text;
  late MergeAwareUndoController undo;
  late List<String> changes;

  Future<void> pumpField(
    WidgetTester tester, {
    bool vim = false,
    bool flutterHistory = false,
  }) async {
    text = TextEditingController();
    undo = MergeAwareUndoController(text);
    changes = [];
    final focusNode = FocusNode();
    addTearDown(() {
      undo.dispose();
      text.dispose();
      focusNode.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: vim,
            child: Scaffold(
              body: TagHighlightedTextField(
                controller: text,
                undoController: flutterHistory ? null : undo,
                focusNode: focusNode,
                maxLines: null,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  /// Types [value] as the whole text, then pauses long enough to make it a
  /// step.
  Future<void> type(WidgetTester tester, String value) async {
    await tester.enterText(find.byType(TextField), value);
    await tester.pump(_pause);
  }

  /// Another device puts "Bedit-" at the start.
  void arriveFromB() {
    final before = text.text;
    final after = 'Bedit-$before';
    undo.applyRemote(
      TextEditingValue(
        text: after,
        selection: TextSelection.collapsed(offset: after.length),
      ),
      previousRemoteText: before,
      remoteText: after,
    );
  }

  testWidgets('Ctrl+Z takes back this device\'s last edit, not text that '
      'arrived from another device', (tester) async {
    await pumpField(tester);
    await type(tester, 'Base by A.');
    await type(tester, 'Base by A. Aedit.');

    arriveFromB();
    expect(text.text, 'Bedit-Base by A. Aedit.');

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'Bedit-Base by A.');
    // Saved like typing, so the field's save carries it.
    expect(changes.last, 'Bedit-Base by A.');

    await _ctrl(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(text.text, 'Bedit-Base by A. Aedit.');
  });

  testWidgets('typing not yet a step is undone to the last step, with the '
      'other device\'s text kept', (tester) async {
    await pumpField(tester);
    await type(tester, 'one');
    await tester.enterText(find.byType(TextField), 'one two');
    await tester.pump(const Duration(milliseconds: 100));
    arriveFromB();

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'Bedit-one');
    await tester.pump(_pause);
  });

  // In the app: "Base by A." then B's "Bedit-" at the start. Diffed from the
  // front that is "edit-B" after the shared "B", which garbled the empty first
  // step into "edit-B".
  testWidgets('undoing back to before any typing keeps the other device\'s '
      'text whole', (tester) async {
    await pumpField(tester);
    await type(tester, 'Base by A.');
    arriveFromB();

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'Bedit-');
  });

  testWidgets('a merge alone leaves nothing to undo', (tester) async {
    await pumpField(tester);
    arriveFromB();
    expect(undo.value.canUndo, isFalse);

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'Bedit-');
  });

  testWidgets('reset forgets the steps of the text loaded before', (
    tester,
  ) async {
    await pumpField(tester);
    await type(tester, 'first record');
    text.text = 'second record';
    undo.reset();

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'second record');
  });

  testWidgets('a saved history comes back, typing not yet a step included', (
    tester,
  ) async {
    await pumpField(tester);
    await type(tester, 'first');
    text.text = 'first and more';
    final saved = undo.saveHistory();
    text.text = 'other record';
    undo.reset();
    text.text = 'first and more';
    undo.restoreHistory(saved);

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'first');
    await _ctrl(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(text.text, 'first and more');
  });

  testWidgets('text changed while its history was away is a step on top', (
    tester,
  ) async {
    await pumpField(tester);
    await type(tester, 'first');
    final saved = undo.saveHistory();
    text.text = 'changed elsewhere';
    undo.restoreHistory(saved);

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'first');
  });

  // Undo put back the caret a step was recorded with: "Hello  world" was a
  // step with the caret after "world", so undoing an `x` on the "o" of
  // "Hello" sent the caret to the "d". It goes to the change instead: its
  // start for Vim, as Vim does, and its end for Ctrl+Z, as desktop editors do.
  testWidgets('Ctrl+Z puts the caret after the text it brings back, and '
      'Ctrl+Y where the text it takes out was', (tester) async {
    await pumpField(tester);
    await type(tester, 'Hello  world');
    text.value = const TextEditingValue(
      text: 'Hell  world',
      selection: TextSelection.collapsed(offset: 4),
    );
    await tester.pump(_pause);
    text.selection = const TextSelection.collapsed(offset: 11);

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(text.text, 'Hello  world');
    expect(text.selection, const TextSelection.collapsed(offset: 5));

    await _ctrl(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(text.text, 'Hell  world');
    expect(text.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets('Vim u and <C-r> put the caret at the change', (tester) async {
    await pumpField(tester, vim: true);
    await type(tester, 'Hello  world');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump(_pause);
    expect(text.text, 'Hell  world');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(text.text, 'Hello  world');
    expect(text.selection.baseOffset, 4);

    await _ctrl(tester, LogicalKeyboardKey.keyR);
    expect(text.text, 'Hell  world');
    expect(text.selection.baseOffset, 4);
  });

  testWidgets('Vim u of appended text leaves the caret on the last character, '
      'not past it', (tester) async {
    await pumpField(tester, vim: true);
    await type(tester, 'Hello');
    await type(tester, 'Hello world');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(text.text, 'Hello');
    expect(text.selection.baseOffset, 4);
  });

  testWidgets('Vim u never puts the caret between a letter and its accent', (
    tester,
  ) async {
    await pumpField(tester, vim: true);
    await type(tester, 'cafe\u0301!');
    await type(tester, 'cafe!');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(text.text, 'cafe\u0301!');
    expect(text.selection.baseOffset, 3);
  });

  testWidgets('Vim u puts the caret at the change in a field with Flutter\'s '
      'own history too', (tester) async {
    await pumpField(tester, vim: true, flutterHistory: true);
    await type(tester, 'Hello  world');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump(_pause);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(text.text, 'Hello  world');
    expect(text.selection.baseOffset, 4);
    // The unattached merge-aware history still listens; let its timer run.
    await tester.pump(_pause);
  });
}

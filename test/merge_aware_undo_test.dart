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

  Future<void> pumpField(WidgetTester tester) async {
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
            enabled: false,
            child: Scaffold(
              body: TagHighlightedTextField(
                controller: text,
                undoController: undo,
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
}

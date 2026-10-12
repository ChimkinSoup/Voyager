import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/single_line_vertical_caret.dart';

void main() {
  /// A centred field under an app that installs the action at its root, as
  /// VoyagerApp does — or doesn't, for [guarded] false.
  Future<EditableTextState> pumpField(
    WidgetTester tester, {
    required bool guarded,
    bool withController = true,
    bool enableInteractiveSelection = true,
    int maxLines = 1,
  }) async {
    final controller = withController
        ? TextEditingController(text: '9:30')
        : null;
    final focusNode = FocusNode();
    if (controller != null) addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        actions: guarded
            ? {
                ...WidgetsApp.defaultActions,
                DirectionalCaretMovementIntent: SingleLineVerticalCaretAction(),
              }
            : null,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textAlign: TextAlign.center,
                maxLines: maxLines,
                enableInteractiveSelection: enableInteractiveSelection,
              ),
            ),
          ),
        ),
      ),
    );
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    if (controller == null) state.widget.controller.text = '9:30';
    focusNode.requestFocus();
    await tester.pump();
    state.widget.controller.selection = const TextSelection.collapsed(
      offset: 2,
    );
    await tester.pump();
    return state;
  }

  testWidgets('bare centered field asserts on Arrow Down (Flutter bug)', (
    tester,
  ) async {
    await pumpField(tester, guarded: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(tester.takeException(), isAssertionError);
  });

  testWidgets('arrows move to the ends without asserting', (tester) async {
    final controller = (await pumpField(
      tester,
      guarded: true,
    )).widget.controller;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(controller.selection, const TextSelection.collapsed(offset: 4));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(controller.selection, const TextSelection.collapsed(offset: 0));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 4),
    );
  });

  testWidgets('covers a field that makes its own controller', (tester) async {
    final controller = (await pumpField(
      tester,
      guarded: true,
      withController: false,
    )).widget.controller;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(tester.takeException(), isNull);
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets('Shift+arrow only moves the caret when selection is off', (
    tester,
  ) async {
    final controller = (await pumpField(
      tester,
      guarded: true,
      enableInteractiveSelection: false,
    )).widget.controller;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets('leaves a multi-line field to Flutter', (tester) async {
    final state = await pumpField(tester, guarded: true, maxLines: 3);
    state.widget.controller.value = const TextEditingValue(
      text: 'ab\ncd',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pump();

    // Flutter's own action moves one line down, keeping the column; this one
    // would have jumped to the end.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(
      state.widget.controller.selection,
      const TextSelection.collapsed(offset: 4),
    );
  });

  testWidgets('turns arrows down while there is no selection', (tester) async {
    // Disabled, the key goes on to whatever handles arrows above the field,
    // as it would past Flutter's own action. (A focused field puts back an
    // invalid selection before a key reaches it, so this asks the action,
    // from the context a key would come from, once focus has gone.)
    final state = await pumpField(tester, guarded: true);
    final focused = FocusManager.instance.primaryFocus!.context!;
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    final action = SingleLineVerticalCaretAction();
    const intent = ExtendSelectionVerticallyToAdjacentLineIntent(
      forward: true,
      collapseSelection: true,
    );

    state.widget.controller.selection = const TextSelection.collapsed(
      offset: -1,
    );
    expect(action.isEnabled(intent, focused), isFalse);
    state.widget.controller.selection = const TextSelection.collapsed(
      offset: 2,
    );
    expect(action.isEnabled(intent, focused), isTrue);
  });
}

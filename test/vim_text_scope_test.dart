import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

/// Exercises the real widget path: a focused field, keys delivered through
/// [WidgetTester.sendKeyEvent] so `VimTextScope`'s ancestor [Focus] has to
/// claim them, and mutations landing via
/// `EditableTextState.userUpdateTextEditingValue` (which the unit tests in
/// `vim_session_test.dart` deliberately bypass).
void main() {
  late TextEditingController controller;
  final List<String> changes = [];

  setUp(() {
    controller = TextEditingController();
    changes.clear();
    VimRegister.text = '';
    VimRegister.linewise = false;
    VimSearchMemory.pattern = '';
  });

  tearDown(() => controller.dispose());

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': 'outside'};
          }
          return null;
        });
  });

  Future<void> pumpField(
    WidgetTester tester, {
    required bool vimEnabled,
    String text = '',
    bool multiline = false,
    bool obscure = false,
    String? hintText,
  }) async {
    controller.text = text;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpWidget(
      // Multiline fields switch on spellcheck, which reads its service from a
      // Riverpod container.
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: vimEnabled,
            child: Scaffold(
              body: LabeledTextField(
                label: 'Body',
                hintText: hintText,
                controller: controller,
                obscureText: obscure,
                maxLines: multiline ? null : 1,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    // Tapping puts the caret wherever the tap landed; every test below reads
    // from a known position instead.
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  Future<void> typeCommand(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      await tester.sendKeyEvent(_keyFor(ch));
      await tester.pump();
    }
  }

  testWidgets('fields start in Insert and type normally', (tester) async {
    await pumpField(tester, vimEnabled: true, text: 'hello');
    await tester.enterText(find.byType(TextField), 'hello world');
    expect(controller.text, 'hello world');
  });

  testWidgets('Escape enters Normal mode and letters stop inserting', (
    tester,
  ) async {
    await pumpField(tester, vimEnabled: true, text: 'abc');
    await press(tester, LogicalKeyboardKey.escape);

    // 'x' is a Vim command here, not a character: the text must lose a
    // character rather than gain one.
    await typeCommand(tester, 'x');
    expect(controller.text, 'bc');
  });

  testWidgets('a at the end of a line keeps the caret on that line', (
    tester,
  ) async {
    // Flutter paints a caret sitting on a `\n` at the start of the next line
    // unless affinity is upstream. `a` on the last character used to take that
    // path and drop the Insert caret onto the left of the line below.
    await pumpField(
      tester,
      vimEnabled: true,
      text: 'one\ntwo',
      multiline: true,
    );
    await press(tester, LogicalKeyboardKey.escape);
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    await typeCommand(tester, 'a');
    expect(controller.selection.baseOffset, 3);
    expect(controller.selection.affinity, TextAffinity.upstream);
  });

  testWidgets('a at the end of a wrapped line keeps the caret on that line', (
    tester,
  ) async {
    // Soft wrap is the same affinity trap without a `\n`: `a` after the last
    // glyph of a visual line sits at the wrap offset, and downstream paints
    // that at the left of the line below.
    const text = 'MMMMMMMMMMMMMMMMMMMM';
    controller.text = text;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                width: 80,
                child: LabeledTextField(
                  label: 'Body',
                  controller: controller,
                  maxLines: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();

    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    double topAt(
      int offset, {
      TextAffinity affinity = TextAffinity.downstream,
    }) {
      return editable
          .getLocalRectForCaret(
            TextPosition(offset: offset, affinity: affinity),
          )
          .top;
    }

    final starts = <int>[];
    double? previous;
    for (var i = 0; i <= text.length; i++) {
      final top = topAt(i);
      if (previous == null || (top - previous).abs() > 0.5) starts.add(i);
      previous = top;
    }
    expect(starts.length, greaterThan(1), reason: 'text must wrap');
    final wrap = starts[1];

    await press(tester, LogicalKeyboardKey.escape);
    controller.selection = TextSelection.collapsed(offset: wrap - 1);
    await tester.pump();

    await typeCommand(tester, 'a');
    expect(controller.selection.baseOffset, wrap);
    expect(controller.selection.affinity, TextAffinity.upstream);
    expect(
      topAt(wrap, affinity: controller.selection.affinity),
      closeTo(topAt(0), 0.5),
    );
  });

  testWidgets('mode badge appears in Normal and hides in Insert', (
    tester,
  ) async {
    await pumpField(tester, vimEnabled: true, text: 'abc');
    expect(find.text('NORMAL'), findsNothing);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('NORMAL'), findsOneWidget);

    await typeCommand(tester, 'i');
    expect(find.text('NORMAL'), findsNothing);
  });

  testWidgets('empty-field hint stays up in Normal mode', (tester) async {
    // Entering Normal mode is not writing, so the placeholder stays put and the
    // block caret covers its first letter instead — see
    // [VimTextOverlay.hintText]. Only text in the document takes it away, which
    // is InputDecorator's own doing.
    const hint = 'Start writing...';
    await pumpField(tester, vimEnabled: true, hintText: hint);
    expect(find.text(hint), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text(hint), findsOneWidget);

    await typeCommand(tester, 'i');
    expect(find.text(hint), findsOneWidget);
  });

  testWidgets('a pending operator shows in the badge', (tester) async {
    await pumpField(tester, vimEnabled: true, text: 'one two');
    await press(tester, LogicalKeyboardKey.escape);
    await typeCommand(tester, '2d');
    expect(find.text('NORMAL  2d'), findsOneWidget);

    await typeCommand(tester, 'w');
    expect(find.text('NORMAL'), findsOneWidget);
  });

  testWidgets('edits fire onChanged, so autosave still sees them', (
    tester,
  ) async {
    await pumpField(tester, vimEnabled: true, text: 'alpha beta');
    await press(tester, LogicalKeyboardKey.escape);
    changes.clear();

    await typeCommand(tester, 'dw');
    expect(controller.text, 'beta');
    expect(changes, ['beta']);
  });

  testWidgets('u undoes a Vim edit through the field undo stack', (
    tester,
  ) async {
    await pumpField(tester, vimEnabled: true, text: 'alpha beta');
    // `u` drives Flutter's own UndoHistory, which throttles pushes at 500ms
    // (undo_history.dart, _kThrottleDuration) — so the pre-edit state has to
    // have landed on the stack before the edit, and the edit before the undo.
    // Two Vim commands inside one 500ms window coalesce into a single undo
    // step, exactly as fast typing does.
    await tester.pump(const Duration(milliseconds: 600));

    await press(tester, LogicalKeyboardKey.escape);
    await typeCommand(tester, 'dw');
    expect(controller.text, 'beta');

    await tester.pump(const Duration(milliseconds: 600));
    await typeCommand(tester, 'u');
    await tester.pump();
    expect(controller.text, 'alpha beta');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.text, 'beta');
  });

  testWidgets(
    'u after a numbered-list renumber does not trip UndoHistory assert',
    (tester) async {
      // Journal/dream/todo onChanged calls applyListEditing, which writes
      // controller.value during the same turn as UndoHistory.onTriggered.
      // Without suppressListEditingWrites that trips
      // `widget.value.value == nextValue` in undo_history.dart.
      //
      // Reproduce by committing an inconsistently numbered value to the undo
      // stack (renumber suppressed), then renumbering, then undoing back to
      // the inconsistent snapshot — onChanged would rewrite it mid-restore.
      var lastText = '1. a\n2. b';
      var suppressRenumber = false;
      controller.text = lastText;
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: VimEnabledScope(
              enabled: true,
              child: Scaffold(
                body: LabeledTextField(
                  label: 'Body',
                  controller: controller,
                  maxLines: null,
                  onChanged: (_) {
                    if (!suppressRenumber) {
                      applyListEditing(
                        controller: controller,
                        previousText: lastText,
                      );
                    }
                    lastText = controller.text;
                    changes.add(controller.text);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump(const Duration(milliseconds: 600));

      final editable = tester.state<EditableTextState>(find.byType(EditableText));

      // Commit "1. a\n5. b" without renumbering so the stack holds it.
      suppressRenumber = true;
      editable.userUpdateTextEditingValue(
        const TextEditingValue(
          text: '1. a\n5. b',
          selection: TextSelection.collapsed(offset: 8),
        ),
        SelectionChangedCause.keyboard,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.text, '1. a\n5. b');

      // Renumber to the consistent form users actually see.
      suppressRenumber = false;
      applyListEditing(controller: controller, previousText: lastText);
      lastText = controller.text;
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.text, '1. a\n2. b');

      await press(tester, LogicalKeyboardKey.escape);
      await typeCommand(tester, 'u');
      await tester.pump();
      // Restore keeps the historical snapshot; renumber stays suspended for
      // the undo turn so UndoHistory's assert holds.
      expect(controller.text, '1. a\n5. b');
    },
  );

  testWidgets('<C-v> pastes the OS clipboard without displacing the register', (
    tester,
  ) async {
    await pumpField(tester, vimEnabled: true, text: 'alpha beta');
    await press(tester, LogicalKeyboardKey.escape);
    await typeCommand(tester, 'yiw');
    expect(VimRegister.text, 'alpha');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Reading the clipboard is an async platform call.
    await tester.idle();
    await tester.pump();

    // Put after the caret, as `p` does.
    expect(controller.text, 'aoutsidelpha beta');
    // The external text went in without becoming the new unnamed register, so
    // a later `p` still puts the yank.
    expect(VimRegister.text, 'alpha');
  });

  /// A field under an ancestor Escape handler, standing in for the dialog or
  /// popover the box is usually sitting inside.
  Future<void> pumpFieldUnderDismissHandler(
    WidgetTester tester, {
    required bool vimEnabled,
    required VoidCallback onDismiss,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: vimEnabled,
            child: Scaffold(
              body: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.escape): _DismissIntent(),
                },
                child: Actions(
                  actions: {
                    _DismissIntent: CallbackAction<_DismissIntent>(
                      onInvoke: (_) {
                        onDismiss();
                        return null;
                      },
                    ),
                  },
                  child: LabeledTextField(
                    label: 'Body',
                    controller: controller,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  testWidgets('a focused Vim field never lets Escape reach the dialog', (
    tester,
  ) async {
    var dismissed = false;
    controller.text = 'abc';
    await pumpFieldUnderDismissHandler(
      tester,
      vimEnabled: true,
      onDismiss: () => dismissed = true,
    );

    // The transition into Normal, then presses with nothing left to cancel —
    // the reflexive Esc-spam that used to close the popup out from under the
    // half-typed form.
    for (var i = 0; i < 5; i++) {
      await press(tester, LogicalKeyboardKey.escape);
      expect(dismissed, isFalse);
    }
    expect(controller.text, 'abc');

    // Same from Visual mode, both the press that leaves it and the ones after.
    await typeCommand(tester, 'v');
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.escape);
      expect(dismissed, isFalse);
    }
  });

  testWidgets('linewise Visual then Esc then i keeps the input connection', (
    tester,
  ) async {
    // Single-line fields used to mount TextSelectionTheme only in Visual.
    // Unmounting it on Esc rebuilt EditableTextState; the fresh state never
    // reopened a text-input connection, so `i` looked focused but swallowed
    // typing. Multiline (journal body) already kept the wrapper mounted.
    await pumpField(tester, vimEnabled: true, text: 'hello');
    final editorState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );

    await press(tester, LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV, character: 'V');
    await tester.pump();
    expect(find.text('V-LINE'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    await typeCommand(tester, 'i');
    expect(find.text('V-LINE'), findsNothing);
    expect(find.text('NORMAL'), findsNothing);
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      same(editorState),
      reason: 'the field must be carried across Visual, not rebuilt',
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'xhello',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(controller.text, 'xhello');
  });

  testWidgets('a field without Vim still lets Escape dismiss', (tester) async {
    var dismissed = false;
    controller.text = 'abc';
    await pumpFieldUnderDismissHandler(
      tester,
      vimEnabled: false,
      onDismiss: () => dismissed = true,
    );

    await press(tester, LogicalKeyboardKey.escape);
    expect(dismissed, isTrue);
  });

  testWidgets('the / bar absorbs typing and jumps to a match', (tester) async {
    await pumpField(
      tester,
      vimEnabled: true,
      text: 'alpha bravo alpha',
      multiline: true,
    );
    await press(tester, LogicalKeyboardKey.escape);
    await typeCommand(tester, '/');
    await typeCommand(tester, 'bravo');
    await tester.pump();

    // Typing inside the search bar must not reach the document.
    expect(controller.text, 'alpha bravo alpha');
    expect(find.text('bravo'), findsOneWidget); // the bar's query
    // The match counter, with a pipe rather than a slash — a slash right next
    // to a `/`-search reads as part of the pattern.
    expect(find.text('1|1'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.enter);
    expect(controller.selection.baseOffset, 6);
    expect(VimSearchMemory.pattern, 'bravo');
  });

  testWidgets('Vim stays off when the setting is disabled', (tester) async {
    await pumpField(tester, vimEnabled: false, text: 'abc');
    await press(tester, LogicalKeyboardKey.escape);
    await typeCommand(tester, 'x');

    // No mode was entered, so 'x' was never a command.
    expect(find.text('NORMAL'), findsNothing);
    expect(controller.text, 'abc');
  });

  testWidgets('obscured fields never get Vim', (tester) async {
    await pumpField(tester, vimEnabled: true, text: 'secret', obscure: true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('NORMAL'), findsNothing);
  });

  testWidgets('the scope is not a Tab stop in front of the field', (
    tester,
  ) async {
    // Regression guard: `Focus(focusNode: …)` re-asserts its own defaults onto
    // the node, which would make the Vim scope focusable and swallow the first
    // Tab press. Only `Focus.withExternalFocusNode` leaves the node alone.
    await pumpField(tester, vimEnabled: true, text: 'abc');
    final vimNode = FocusManager.instance.primaryFocus!.ancestors.firstWhere(
      (node) => node.debugLabel == 'VimTextScope',
      orElse: () =>
          throw StateError('VimTextScope node not in the focus chain'),
    );
    expect(vimNode.canRequestFocus, isFalse);
    expect(vimNode.skipTraversal, isTrue);
  });

  /// Drives the app lifecycle the way the embedder does, so [FocusManager]
  /// suspends and restores the primary focus exactly as it would on a real
  /// Alt-Tab. (Desktop only: the manager ignores lifecycle changes on mobile.)
  Future<void> setAppLifecycleState(AppLifecycleState state) async {
    final message = const StringCodec().encodeMessage(state.toString());
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('flutter/lifecycle', message, (_) {});
  }

  testWidgets(
    'switching to another app and back keeps the mode and the Visual range',
    (tester) async {
      // Leaving the app parks the field's focus (FocusManager suspends the
      // primary focus whenever the app stops being `resumed`), which used to
      // look like "the user left the box": the session reset to Insert and the
      // Visual selection collapsed with it.
      await pumpField(tester, vimEnabled: true, text: 'alpha beta');
      await press(tester, LogicalKeyboardKey.escape);
      await typeCommand(tester, 'vll');
      expect(find.text('VISUAL'), findsOneWidget);
      final selected = controller.selection;
      expect(selected.textInside(controller.text), 'alp');

      final fieldNode = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;

      await setAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        fieldNode.hasPrimaryFocus,
        isFalse,
        reason: 'the framework must park the focus, or this proves nothing',
      );
      expect(controller.selection, selected);

      await setAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(fieldNode.hasPrimaryFocus, isTrue);
      expect(controller.selection, selected);
      expect(find.text('VISUAL'), findsOneWidget);

      // Still a live Visual selection, not a caret in Insert: `x` cuts it.
      await typeCommand(tester, 'x');
      expect(controller.text, 'ha beta');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a field that loses focus while the app is away still resets to Insert',
    (tester) async {
      // The other side of the app-switch case: focus went somewhere else while
      // the app was gone, so the framework has nothing to hand back. The field
      // is genuinely abandoned and must not greet the next click in Normal.
      final decoy = FocusNode(debugLabel: 'decoy');
      addTearDown(decoy.dispose);
      controller.text = 'abc';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: VimEnabledScope(
              enabled: true,
              child: Scaffold(
                body: Column(
                  children: [
                    LabeledTextField(label: 'Body', controller: controller),
                    Focus(
                      focusNode: decoy,
                      child: const SizedBox(width: 20, height: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('NORMAL'), findsOneWidget);

      await setAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      decoy.requestFocus();
      await tester.pump();

      await setAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('NORMAL'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  /// The *other* signal a window switch arrives by: the engine reports view
  /// focus on its own channel, and `View` parks the primary focus the moment
  /// the view is unfocused — with no lifecycle message involved. On Windows
  /// this one lands first, which is why consulting only the lifecycle state
  /// used to read an Alt-Tab as "the user left this field".
  void setViewFocus(WidgetTester tester, ViewFocusState state) {
    WidgetsBinding.instance.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: state,
        direction: ViewFocusDirection.undefined,
      ),
    );
  }

  testWidgets(
    'a window blur with no lifecycle message keeps the mode and the range',
    (tester) async {
      await pumpField(tester, vimEnabled: true, text: 'alpha beta');
      await press(tester, LogicalKeyboardKey.escape);
      await typeCommand(tester, 'vll');
      expect(find.text('VISUAL'), findsOneWidget);
      final selected = controller.selection;
      expect(selected.textInside(controller.text), 'alp');

      setViewFocus(tester, ViewFocusState.unfocused);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        FocusManager.instance.rootScope,
        reason: 'the framework must park the focus, or this proves nothing',
      );
      // The badge follows the field's focus, so it is down while the window
      // is away; the range underneath it is what must survive.
      expect(controller.selection, selected);

      setViewFocus(tester, ViewFocusState.focused);
      await tester.pump();
      expect(find.text('VISUAL'), findsOneWidget);
      expect(controller.selection, selected);

      // Still a live Visual selection, not a caret in Insert: `x` cuts it.
      await typeCommand(tester, 'x');
      expect(controller.text, 'ha beta');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the select-all a single-line field does on refocus is undone',
    (tester) async {
      // `EditableText.selectAllOnFocus` fires when the framework hands the
      // focus back at the end of the switch. Normal mode would come back with
      // its caret at the end of the field.
      await pumpField(tester, vimEnabled: true, text: 'alpha beta');
      await press(tester, LogicalKeyboardKey.escape);
      await typeCommand(tester, 'll');
      final caret = controller.selection;
      expect(caret.baseOffset, 2);

      setViewFocus(tester, ViewFocusState.unfocused);
      await tester.pump();
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
      setViewFocus(tester, ViewFocusState.focused);
      await tester.pump();

      expect(find.text('NORMAL'), findsOneWidget);
      expect(controller.selection, caret);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a field abandoned during a window blur still resets to Insert',
    (tester) async {
      final decoy = FocusNode(debugLabel: 'decoy');
      addTearDown(decoy.dispose);
      controller.text = 'abc';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: VimEnabledScope(
              enabled: true,
              child: Scaffold(
                body: Column(
                  children: [
                    LabeledTextField(label: 'Body', controller: controller),
                    Focus(
                      focusNode: decoy,
                      child: const SizedBox(width: 20, height: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('NORMAL'), findsOneWidget);

      setViewFocus(tester, ViewFocusState.unfocused);
      await tester.pump();
      decoy.requestFocus();
      await tester.pump();

      setViewFocus(tester, ViewFocusState.focused);
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('NORMAL'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('leaving the field resets it to Insert', (tester) async {
    await pumpField(tester, vimEnabled: true, text: 'abc');
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('NORMAL'), findsOneWidget);

    final scope = tester.state<State<VimTextScope>>(find.byType(VimTextScope));
    FocusScope.of(scope.context).unfocus();
    await tester.pump();
    expect(find.text('NORMAL'), findsNothing);
  });
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}

/// Maps a command character to the key that produces it. Only the characters
/// the tests actually send need to be here.
LogicalKeyboardKey _keyFor(String ch) {
  const map = <String, LogicalKeyboardKey>{
    '/': LogicalKeyboardKey.slash,
    '2': LogicalKeyboardKey.digit2,
  };
  final mapped = map[ch];
  if (mapped != null) return mapped;
  final key = LogicalKeyboardKey.knownLogicalKeys.firstWhere(
    (k) => k.keyLabel.toLowerCase() == ch.toLowerCase(),
    orElse: () => throw ArgumentError('No key for "$ch"'),
  );
  return key;
}

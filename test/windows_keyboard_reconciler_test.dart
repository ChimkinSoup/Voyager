import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

/// A modifier whose key-up went to another window stays in [HardwareKeyboard]'s
/// pressed set for the rest of the process, and nothing in the framework takes
/// it back out again.
///
/// The first group pins the damage that does, so it stays visible if the fix
/// below is ever unwired; the second pins the fix.
///
/// Reported 2026-09-05: `Win+Shift+S` put a screenshot on the clipboard and
/// left Meta stuck. Ctrl+V and Ctrl+A went dead in the LeetCode code field, and
/// the Explanation field below it — reached through `VimTextScope`'s own paste
/// path, which accepts Meta — pasted fine, which is what pinned it to Meta
/// rather than Alt. Escape still entered Normal mode, and every Vim command
/// after it typed itself out as literal text. Only restarting the app fixed it.
void main() {
  late TextEditingController controller;

  setUp(() {
    controller = TextEditingController();
  });

  tearDown(() {
    controller.dispose();
    WindowsKeyboardReconciler.debugProbe = null;
    WindowsKeyboardReconciler.instance.uninstall();
    _releaseAll();
  });

  /// Models the framework having missed a key-up: the key goes down and never
  /// comes back up, which is the whole of the bug.
  void stick(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) {
    HardwareKeyboard.instance.handleKeyEvent(
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      ),
    );
  }

  Future<void> pumpField(WidgetTester tester, {required String text}) async {
    controller.text = text;
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
                maxLines: 1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  group('a stuck modifier', () {
    testWidgets('traps a Vim field in Normal mode with every command dead', (
      tester,
    ) async {
      await pumpField(tester, text: 'abc');
      stick(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);

      // Escape still works: `VimSession.handleKey` checks for it while in
      // Insert *before* it reaches the `alt || meta` guard.
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('NORMAL'), findsOneWidget);

      // Everything past that guard is declined and falls through to the field,
      // which in the running app is what types the command out as text.
      await press(tester, LogicalKeyboardKey.keyX);
      expect(controller.text, 'abc', reason: 'x should have deleted a char');

      // Including the way back out, so the field cannot be recovered.
      await press(tester, LogicalKeyboardKey.keyI);
      expect(find.text('NORMAL'), findsOneWidget);
    });

    testWidgets('is what the reconciler exists to clear', (tester) async {
      await pumpField(tester, text: 'abc');
      stick(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      await press(tester, LogicalKeyboardKey.escape);

      // The OS says nothing is held, so the stale Meta goes.
      WindowsKeyboardReconciler.debugProbe = (_) => false;
      expect(WindowsKeyboardReconciler.instance.reconcile(), 1);
      expect(HardwareKeyboard.instance.isMetaPressed, isFalse);

      await press(tester, LogicalKeyboardKey.keyX);
      expect(controller.text, 'bc');
      await press(tester, LogicalKeyboardKey.keyI);
      expect(find.text('NORMAL'), findsNothing);
    });
  });

  group('the reconciler', () {
    test('leaves a key the OS still reports as held alone', () {
      stick(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft);
      WindowsKeyboardReconciler.debugProbe = (_) => true;

      expect(WindowsKeyboardReconciler.instance.reconcile(), 0);
      expect(HardwareKeyboard.instance.isAltPressed, isTrue);
    });

    test('leaves everything alone when there is no native answer', () {
      stick(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      WindowsKeyboardReconciler.debugProbe = (_) => null;

      expect(WindowsKeyboardReconciler.instance.reconcile(), 0);
      expect(HardwareKeyboard.instance.isMetaPressed, isTrue);
    });

    test('releases each stale modifier exactly once', () {
      stick(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      stick(PhysicalKeyboardKey.shiftRight, LogicalKeyboardKey.shiftRight);
      WindowsKeyboardReconciler.debugProbe = (_) => false;

      expect(WindowsKeyboardReconciler.instance.reconcile(), 2);
      expect(WindowsKeyboardReconciler.instance.reconcile(), 0);
      expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
    });

    test('never touches a non-modifier key', () {
      stick(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);
      WindowsKeyboardReconciler.debugProbe = (_) => false;

      expect(WindowsKeyboardReconciler.instance.reconcile(), 0);
      expect(
        HardwareKeyboard.instance.physicalKeysPressed,
        contains(PhysicalKeyboardKey.keyA),
      );
    });
  });

  group('wiring', () {
    /// A window switch reaches the framework on the view-focus channel, and on
    /// Windows it can arrive with no lifecycle message at all — which is why
    /// the old `AppLifecycleState.resumed` hook never ran for this.
    void setViewFocus(WidgetTester tester, ViewFocusState state) {
      WidgetsBinding.instance.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: state,
          direction: ViewFocusDirection.undefined,
        ),
      );
    }

    testWidgets('regaining window focus clears the stale modifier', (
      tester,
    ) async {
      await pumpField(tester, text: 'abc');
      WindowsKeyboardReconciler.instance.install();
      WindowsKeyboardReconciler.debugProbe = (_) => false;

      setViewFocus(tester, ViewFocusState.unfocused);
      stick(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      expect(HardwareKeyboard.instance.isMetaPressed, isTrue);

      setViewFocus(tester, ViewFocusState.focused);
      await tester.pump();
      expect(HardwareKeyboard.instance.isMetaPressed, isFalse);
    });

    testWidgets('the armed one-shot catches a key stuck after the switch', (
      tester,
    ) async {
      await pumpField(tester, text: 'abc');
      WindowsKeyboardReconciler.instance.install();

      // Focus comes back while the key is genuinely still held, so both reads
      // on the way in correctly leave it be.
      WindowsKeyboardReconciler.debugProbe = (_) => true;
      setViewFocus(tester, ViewFocusState.unfocused);
      stick(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      setViewFocus(tester, ViewFocusState.focused);
      await tester.pump();
      expect(HardwareKeyboard.instance.isMetaPressed, isTrue);

      // It was released while we were not looking, and the next key is what
      // notices. That key is still lost — the reconcile is deferred out of
      // HardwareKeyboard's dispatch loop — but the one after it is not.
      WindowsKeyboardReconciler.debugProbe = (_) => false;
      await press(tester, LogicalKeyboardKey.keyZ);
      await tester.pump();
      expect(HardwareKeyboard.instance.isMetaPressed, isFalse);
    });
  });
}

/// Leaves [HardwareKeyboard] clean for the next test, whatever a test stuck.
void _releaseAll() {
  for (final physical in HardwareKeyboard.instance.physicalKeysPressed) {
    HardwareKeyboard.instance.handleKeyEvent(
      KeyUpEvent(
        physicalKey: physical,
        logicalKey: HardwareKeyboard.instance.lookUpLayout(physical)!,
        timeStamp: Duration.zero,
        synthesized: true,
      ),
    );
  }
}

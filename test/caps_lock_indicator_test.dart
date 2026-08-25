import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/caps_lock/caps_lock_caret_indicator.dart';
import 'package:voyager/core/caps_lock/caps_lock_indicator_scope.dart';
import 'package:voyager/core/caps_lock/caps_lock_state.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// A field wide enough that the caret sits nowhere near the trailing edge, so
/// the mark takes its ordinary right-hand placement.
const double _wideField = 320;

/// The right edge of the field's thin caret at [offset], in the indicator's
/// own coordinates — which is where the mark's gap starts everywhere but Vim's
/// Normal mode.
double _caretRight(WidgetTester tester, int offset) {
  final render = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  final box = render.localToGlobal(Offset.zero);
  return box.dx +
      render.getLocalRectForCaret(TextPosition(offset: offset)).right -
      tester.getTopLeft(find.byType(CapsLockCaretIndicator)).dx;
}

void main() {
  group('capsLockBadgeVisible', () {
    bool visible({
      bool scopeEnabled = true,
      bool allowedHere = true,
      bool focused = true,
      bool readOnly = false,
      bool capsLockOn = true,
      bool selectionCollapsed = true,
    }) {
      return capsLockBadgeVisible(
        scopeEnabled: scopeEnabled,
        allowedHere: allowedHere,
        focused: focused,
        readOnly: readOnly,
        capsLockOn: capsLockOn,
        selectionCollapsed: selectionCollapsed,
      );
    }

    test('shows with everything satisfied', () {
      expect(visible(), isTrue);
    });

    test('hides when the setting or the platform says no', () {
      expect(visible(scopeEnabled: false), isFalse);
    });

    test('hides on a field that opted out', () {
      expect(visible(allowedHere: false), isFalse);
    });

    test('hides with no field focused', () {
      expect(visible(focused: false), isFalse);
    });

    test('hides on a read-only field', () {
      expect(visible(readOnly: true), isFalse);
    });

    test('hides with Caps Lock off', () {
      expect(visible(capsLockOn: false), isFalse);
    });

    test('hides on a range selection, which covers a Visual highlight too', () {
      expect(visible(selectionCollapsed: false), isFalse);
    });
  });

  group('CapsLockState', () {
    tearDown(() {
      CapsLockState.debugProbe = null;
      CapsLockState.instance.sync();
    });

    test('falls back to the framework lock modes with no native probe', () {
      CapsLockState.debugProbe = () => null;
      void listener() {}
      CapsLockState.instance.addListener(listener);
      addTearDown(() => CapsLockState.instance.removeListener(listener));
      expect(
        CapsLockState.instance.isOn,
        HardwareKeyboard.instance.lockModesEnabled.contains(
          KeyboardLockMode.capsLock,
        ),
      );
    });

    test('a native answer wins over the framework lock modes', () {
      CapsLockState.debugProbe = () => true;
      void listener() {}
      CapsLockState.instance.addListener(listener);
      addTearDown(() => CapsLockState.instance.removeListener(listener));
      expect(CapsLockState.instance.isOn, isTrue);
    });

    test('notifies only when the answer moves', () {
      var caps = false;
      CapsLockState.debugProbe = () => caps;
      var notifications = 0;
      void listener() => notifications++;
      CapsLockState.instance.addListener(listener);
      addTearDown(() => CapsLockState.instance.removeListener(listener));

      CapsLockState.instance.sync();
      expect(notifications, 0);

      // The resync a window regain triggers, with the key pressed elsewhere:
      // no key event ever reached the framework, and the badge still updates.
      caps = true;
      CapsLockState.instance.sync();
      expect(notifications, 1);
      expect(CapsLockState.instance.isOn, isTrue);

      CapsLockState.instance.sync();
      expect(notifications, 1);
    });
  });

  group('caret mark', () {
    late TextEditingController controller;
    late FocusNode focusNode;

    setUp(() {
      debugCapsLockMarkRect = null;
      CapsLockState.debugProbe = () => true;
      controller = TextEditingController(text: 'hello world');
      focusNode = FocusNode();
    });

    tearDown(() {
      CapsLockState.debugProbe = null;
      CapsLockState.instance.sync();
      controller.dispose();
    });

    Future<void> pumpField(
      WidgetTester tester, {
      bool settingEnabled = true,
      bool vimEnabled = false,
      double width = _wideField,
      bool readOnly = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: VimEnabledScope(
                  enabled: vimEnabled,
                  child: CapsLockIndicatorScope(
                    enabled: settingEnabled,
                    child: VoyagerTextField(
                      controller: controller,
                      focusNode: focusNode,
                      enabled: !readOnly,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// Focuses the field and puts a collapsed caret at [offset], then lets the
    /// fade run out.
    Future<void> focusCaretAt(WidgetTester tester, int offset) async {
      focusNode.requestFocus();
      await tester.pump();
      controller.selection = TextSelection.collapsed(offset: offset);
      await tester.pump();
      await tester.pump(kCapsLockIndicatorFade);
      await tester.pump();
    }

    testWidgets(
      'draws beside the caret of a focused field',
      (tester) async {
        await pumpField(tester);
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNotNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'draws nothing while the field is unfocused',
      (tester) async {
        await pumpField(tester);
        await tester.pump(kCapsLockIndicatorFade);
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'goes away when focus leaves the field',
      (tester) async {
        await pumpField(tester);
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNotNull);

        focusNode.unfocus();
        await tester.pump();
        await tester.pump(kCapsLockIndicatorFade);
        await tester.pump();
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'goes away on a range selection',
      (tester) async {
        await pumpField(tester);
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNotNull);

        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        await tester.pump(kCapsLockIndicatorFade);
        await tester.pump();
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'goes away when Caps Lock goes off',
      (tester) async {
        await pumpField(tester);
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNotNull);

        CapsLockState.debugProbe = () => false;
        CapsLockState.instance.sync();
        await tester.pump();
        await tester.pump(kCapsLockIndicatorFade);
        await tester.pump();
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'draws nothing with the setting off',
      (tester) async {
        await pumpField(tester, settingEnabled: false);
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'draws nothing where the system already does, or has no lock key',
      (tester) async {
        await pumpField(tester);
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'sits to the right of the caret',
      (tester) async {
        await pumpField(tester);
        await focusCaretAt(tester, 0);
        final atStart = debugCapsLockMarkRect;
        expect(atStart, isNotNull);

        await focusCaretAt(tester, 5);
        final laterOn = debugCapsLockMarkRect;
        expect(laterOn, isNotNull);
        // Five characters further along the line, so the mark has travelled with
        // the caret rather than parking anywhere fixed.
        expect(laterOn!.left, greaterThan(atStart!.left));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'flips to the left of the caret at the trailing edge',
      (tester) async {
        // Text that fills the field without overflowing it, so the caret lands
        // hard against the trailing edge while still being on screen.
        controller.text = 'aaaaa';
        await pumpField(tester, width: 120);

        await focusCaretAt(tester, 0);
        final atStart = debugCapsLockMarkRect;
        expect(atStart, isNotNull);
        expect(atStart!.left, greaterThan(_caretRight(tester, 0)));

        await focusCaretAt(tester, controller.text.length);
        final atEnd = debugCapsLockMarkRect;
        expect(atEnd, isNotNull, reason: 'it flips rather than disappearing');
        expect(
          atEnd!.right,
          lessThan(_caretRight(tester, controller.text.length)),
          reason: 'with no room on the right it goes left of the caret',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'the code-field opt-out never draws',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CapsLockIndicatorScope(
                enabled: true,
                child: CapsLockCaretIndicator(
                  allowed: false,
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                  ),
                ),
              ),
            ),
          ),
        );
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'an obscured field still gets one',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: _wideField,
                child: CapsLockIndicatorScope(
                  enabled: true,
                  child: CapsLockCaretIndicator(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      obscureText: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await focusCaretAt(tester, 5);
        expect(debugCapsLockMarkRect, isNotNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'Vim Normal mode clears the block caret, not the thin one',
      (tester) async {
        await pumpField(tester, vimEnabled: true);
        await focusCaretAt(tester, 5);
        final insert = debugCapsLockMarkRect;
        expect(insert, isNotNull);

        final render = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        // How far the editable sits inside the indicator's own box, read off
        // the Insert placement: there the gap starts at the thin caret's right
        // edge, so the difference is the field's padding.
        final inset =
            insert!.left -
            render.getLocalRectForCaret(const TextPosition(offset: 5)).right -
            kCapsLockIndicatorGap;

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(kCapsLockIndicatorFade);
        await tester.pump();

        final normal = debugCapsLockMarkRect;
        expect(normal, isNotNull);
        // Esc steps the caret back one, so this asks about the *same* offset in
        // both modes rather than comparing two different characters.
        final caret = controller.selection.baseOffset;
        final block = render
            .getBoxesForSelection(
              TextSelection(baseOffset: caret, extentOffset: caret + 1),
            )
            .first;
        final thin = render.getLocalRectForCaret(TextPosition(offset: caret));
        expect(
          normal!.left,
          closeTo(inset + block.right + kCapsLockIndicatorGap, 0.01),
          reason: 'the gap is measured from the block caret',
        );
        expect(
          normal.left,
          greaterThan(inset + thin.right + kCapsLockIndicatorGap),
          reason: 'which is a whole glyph right of the thin caret it covers',
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('settings plumbing', () {
    test('defaults to on', () {
      expect(const AppSettings().capsLockIndicatorEnabled, isTrue);
    });

    test('rides the settings sync payload both ways', () {
      final payload = settingsSyncPayload(
        const AppSettings(capsLockIndicatorEnabled: false),
      );
      expect(payload['capsLockIndicatorEnabled'], isFalse);

      final merged = mergeSettingsFromRemote({
        ...payload,
        'settingsUpdatedAt': DateTime.utc(2030).toIso8601String(),
      }, const AppSettings());
      expect(merged.capsLockIndicatorEnabled, isFalse);
    });

    test('a document that predates the flag leaves it alone', () {
      final merged = mergeSettingsFromRemote({
        'settingsUpdatedAt': DateTime.utc(2030).toIso8601String(),
      }, const AppSettings());
      expect(merged.capsLockIndicatorEnabled, isTrue);
    });
  });
}

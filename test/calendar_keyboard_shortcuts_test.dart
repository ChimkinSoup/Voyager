import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/key_binding.dart';
import 'package:voyager/features/calendar/calendar_keyboard_shortcuts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseKeyBinding', () {
    test('parses single letter keys', () {
      final binding = parseKeyBinding('H');
      expect(binding?.logicalKey, LogicalKeyboardKey.keyH);
      expect(binding?.control, isFalse);
    });

    test('parses modifier combos', () {
      final binding = parseKeyBinding('Ctrl+Shift+L');
      expect(binding?.logicalKey, LogicalKeyboardKey.keyL);
      expect(binding?.control, isTrue);
      expect(binding?.shift, isTrue);
    });
  });

  group('matchesKeyBinding', () {
    test('matches letter key without modifiers', () {
      final event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyH,
        logicalKey: LogicalKeyboardKey.keyH,
        character: 'h',
        timeStamp: Duration.zero,
      );

      expect(matchesKeyBinding(event, 'H'), isTrue);
      expect(matchesKeyBinding(event, 'L'), isFalse);
    });
  });

  group('calendarNavDeltaForEvent', () {
    test('arrow left and right always map to navigation delta', () {
      final left = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowLeft,
        logicalKey: LogicalKeyboardKey.arrowLeft,
        character: null,
        timeStamp: Duration.zero,
      );
      final right = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        character: null,
        timeStamp: Duration.zero,
      );

      expect(
        calendarNavDeltaForEvent(
          left,
          navigateLeftKey: 'H',
          navigateRightKey: 'L',
          letterKeysEnabled: false,
        ),
        -1,
      );
      expect(
        calendarNavDeltaForEvent(
          right,
          navigateLeftKey: 'H',
          navigateRightKey: 'L',
          letterKeysEnabled: false,
        ),
        1,
      );
    });

    test('letter keys only when enabled', () {
      final h = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyH,
        logicalKey: LogicalKeyboardKey.keyH,
        character: 'h',
        timeStamp: Duration.zero,
      );

      expect(
        calendarNavDeltaForEvent(
          h,
          navigateLeftKey: 'H',
          navigateRightKey: 'L',
          letterKeysEnabled: false,
        ),
        isNull,
      );
      expect(
        calendarNavDeltaForEvent(
          h,
          navigateLeftKey: 'H',
          navigateRightKey: 'L',
          letterKeysEnabled: true,
        ),
        -1,
      );
    });
  });

  group('calendarNavShortcutsEnabledForState', () {
    test('enabled only on current route without overlays or text input', () {
      expect(
        calendarNavShortcutsEnabledForState(
          routeIsCurrent: true,
          rootNavigatorCanPop: false,
          textInputFocused: false,
        ),
        isTrue,
      );
    });

    test('disabled while typing', () {
      expect(
        calendarNavShortcutsEnabledForState(
          routeIsCurrent: true,
          rootNavigatorCanPop: false,
          textInputFocused: true,
        ),
        isFalse,
      );
    });

    test('disabled while overlay route is open', () {
      expect(
        calendarNavShortcutsEnabledForState(
          routeIsCurrent: true,
          rootNavigatorCanPop: true,
          textInputFocused: false,
        ),
        isFalse,
      );
    });
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/shell/shell_keyboard_shortcuts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shell tab index', () {
    test('next wraps from last to first', () {
      expect(nextShellTabIndex(6, 7), 0);
      expect(nextShellTabIndex(0, 7), 1);
    });

    test('previous wraps from first to last', () {
      expect(previousShellTabIndex(0, 7), 6);
      expect(previousShellTabIndex(3, 7), 2);
    });
  });

  group('shell tab shortcut events', () {
    test('ignores plain tab without ctrl', () {
      final event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.tab,
        logicalKey: LogicalKeyboardKey.tab,
        character: null,
        timeStamp: Duration.zero,
      );

      expect(isShellTabShortcutEvent(event), isFalse);
    });

    test('ignores non-tab keys', () {
      final event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyJ,
        logicalKey: LogicalKeyboardKey.keyJ,
        character: 'j',
        timeStamp: Duration.zero,
      );

      expect(isShellTabShortcutEvent(event), isFalse);
    });
  });

  group('shellTabShortcutsEnabledForState', () {
    test('enabled only on supported desktop shell without overlays', () {
      expect(
        shellTabShortcutsEnabledForState(
          platformSupported: true,
          routeIsCurrent: true,
          rootNavigatorCanPop: false,
        ),
        isTrue,
      );
    });

    test('disabled on android', () {
      expect(
        shellTabShortcutsEnabledForState(
          platformSupported: false,
          routeIsCurrent: true,
          rootNavigatorCanPop: false,
        ),
        isFalse,
      );
    });

    test('disabled while a root overlay route is open', () {
      expect(
        shellTabShortcutsEnabledForState(
          platformSupported: true,
          routeIsCurrent: true,
          rootNavigatorCanPop: true,
        ),
        isFalse,
      );
    });

    test('disabled when shell route is not current', () {
      expect(
        shellTabShortcutsEnabledForState(
          platformSupported: true,
          routeIsCurrent: false,
          rootNavigatorCanPop: false,
        ),
        isFalse,
      );
    });
  });
}

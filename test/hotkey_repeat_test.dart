import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/features/hotkeys/hotkey_repeat.dart';

/// A held system hotkey repeats; only its press reaches the handler.
void main() {
  final hotKey = HotKey(
    key: PhysicalKeyboardKey.keyS,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );

  test("repeats are dropped until the combo's key is let go of", () {
    final down = <int>{};
    final keyDown = debugKeyDown;
    debugKeyDown = down.contains;
    addTearDown(() => debugKeyDown = keyDown);
    fakeAsync((async) {
      var presses = 0;
      final handler = onPressOnly((_) => presses++);

      down.add(0x53); // S
      handler(hotKey);
      async.elapse(const Duration(milliseconds: 600));
      handler(hotKey);
      handler(hotKey);
      expect(presses, 1);

      down.clear();
      async.elapse(const Duration(milliseconds: 40));
      down.add(0x53);
      handler(hotKey);
      expect(presses, 2);
    });
  });
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:win32/win32.dart';

/// [handler] for a system hotkey's press, without its repeats.
///
/// hotkey_manager registers without `MOD_NOREPEAT`, so Windows sends
/// `WM_HOTKEY` again at the keyboard's repeat rate for as long as the combo
/// is held: a floater that toggles would open and close, and one that shows
/// would be shown again and again. After a press, further ones are dropped
/// until the combo's key has been seen up.
HotKeyHandler onPressOnly(HotKeyHandler handler) {
  var held = false;
  return (hotKey) {
    if (held) return;
    final virtualKey = _virtualKeys[hotKey.physicalKey.usbHidUsage];
    if (virtualKey != null) {
      held = true;
      Timer.periodic(const Duration(milliseconds: 20), (timer) {
        if (debugKeyDown(virtualKey)) return;
        timer.cancel();
        held = false;
      });
    }
    handler(hotKey);
  };
}

/// Whether [virtualKey] is down now; tests stand in for the keyboard.
@visibleForTesting
bool Function(int virtualKey) debugKeyDown = (virtualKey) =>
    GetAsyncKeyState(virtualKey) & 0x8000 != 0;

/// The keys a hotkey can end on (the hotkey parser's A to Z), by USB HID
/// usage, and their virtual-key codes.
final Map<int, int> _virtualKeys = {
  for (var i = 0; i < 26; i++)
    PhysicalKeyboardKey.keyA.usbHidUsage + i: 0x41 + i,
};

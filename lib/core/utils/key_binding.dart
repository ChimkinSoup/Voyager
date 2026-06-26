import 'package:flutter/services.dart';

/// Parsed in-app key binding (e.g. `H`, `L`, or `Ctrl+Shift+Left`).
class KeyBinding {
  const KeyBinding({
    required this.logicalKey,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey logicalKey;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;
}

KeyBinding? parseKeyBinding(String combo) {
  final parts = combo
      .split('+')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;

  final keyToken = parts.removeLast();
  var control = false;
  var shift = false;
  var alt = false;
  var meta = false;

  for (final part in parts) {
    switch (part.toLowerCase()) {
      case 'ctrl':
      case 'control':
        control = true;
      case 'shift':
        shift = true;
      case 'alt':
        alt = true;
      case 'meta':
      case 'cmd':
      case 'win':
        meta = true;
    }
  }

  final logicalKey = logicalKeyFromToken(keyToken);
  if (logicalKey == null) return null;

  return KeyBinding(
    logicalKey: logicalKey,
    control: control,
    shift: shift,
    alt: alt,
    meta: meta,
  );
}

LogicalKeyboardKey? logicalKeyFromToken(String token) {
  return switch (token.toLowerCase()) {
    'a' => LogicalKeyboardKey.keyA,
    'b' => LogicalKeyboardKey.keyB,
    'c' => LogicalKeyboardKey.keyC,
    'd' => LogicalKeyboardKey.keyD,
    'e' => LogicalKeyboardKey.keyE,
    'f' => LogicalKeyboardKey.keyF,
    'g' => LogicalKeyboardKey.keyG,
    'h' => LogicalKeyboardKey.keyH,
    'i' => LogicalKeyboardKey.keyI,
    'j' => LogicalKeyboardKey.keyJ,
    'k' => LogicalKeyboardKey.keyK,
    'l' => LogicalKeyboardKey.keyL,
    'm' => LogicalKeyboardKey.keyM,
    'n' => LogicalKeyboardKey.keyN,
    'o' => LogicalKeyboardKey.keyO,
    'p' => LogicalKeyboardKey.keyP,
    'q' => LogicalKeyboardKey.keyQ,
    'r' => LogicalKeyboardKey.keyR,
    's' => LogicalKeyboardKey.keyS,
    't' => LogicalKeyboardKey.keyT,
    'u' => LogicalKeyboardKey.keyU,
    'v' => LogicalKeyboardKey.keyV,
    'w' => LogicalKeyboardKey.keyW,
    'x' => LogicalKeyboardKey.keyX,
    'y' => LogicalKeyboardKey.keyY,
    'z' => LogicalKeyboardKey.keyZ,
    'left' => LogicalKeyboardKey.arrowLeft,
    'right' => LogicalKeyboardKey.arrowRight,
    'up' => LogicalKeyboardKey.arrowUp,
    'down' => LogicalKeyboardKey.arrowDown,
    _ => null,
  };
}

String formatKeyBinding(String combo) {
  final binding = parseKeyBinding(combo);
  if (binding == null) return combo;

  final parts = <String>[];
  if (binding.control) parts.add('Ctrl');
  if (binding.shift) parts.add('Shift');
  if (binding.alt) parts.add('Alt');
  if (binding.meta) parts.add('Meta');
  parts.add(_displayToken(binding.logicalKey));
  return parts.join('+');
}

String _displayToken(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) return 'Left';
  if (key == LogicalKeyboardKey.arrowRight) return 'Right';
  if (key == LogicalKeyboardKey.arrowUp) return 'Up';
  if (key == LogicalKeyboardKey.arrowDown) return 'Down';

  final label = key.keyLabel;
  if (label.length == 1) return label.toUpperCase();
  return label;
}

String keyBindingToStorage(KeyBinding binding) {
  final parts = <String>[];
  if (binding.control) parts.add('Ctrl');
  if (binding.shift) parts.add('Shift');
  if (binding.alt) parts.add('Alt');
  if (binding.meta) parts.add('Meta');
  parts.add(_displayToken(binding.logicalKey));
  return parts.join('+');
}

bool matchesKeyBinding(KeyEvent event, String combo) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

  final binding = parseKeyBinding(combo);
  if (binding == null) return false;

  return event.logicalKey == binding.logicalKey &&
      HardwareKeyboard.instance.isControlPressed == binding.control &&
      HardwareKeyboard.instance.isShiftPressed == binding.shift &&
      HardwareKeyboard.instance.isAltPressed == binding.alt &&
      HardwareKeyboard.instance.isMetaPressed == binding.meta;
}

KeyBinding? keyBindingFromKeyEvent(KeyEvent event) {
  if (event is! KeyDownEvent) return null;
  if (HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isMetaPressed) {
    return null;
  }

  final logicalKey = event.logicalKey;
  final token = _displayToken(logicalKey);
  if (logicalKeyFromToken(token) != logicalKey) return null;

  return KeyBinding(
    logicalKey: logicalKey,
    shift: HardwareKeyboard.instance.isShiftPressed,
  );
}

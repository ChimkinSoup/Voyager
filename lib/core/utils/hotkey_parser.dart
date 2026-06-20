import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

HotKey? parseHotKey(String combo) {
  final parts = combo
      .split('+')
      .map((p) => p.trim().toLowerCase())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;

  final keyToken = parts.removeLast();
  final modifiers = <HotKeyModifier>[];

  for (final part in parts) {
    switch (part) {
      case 'ctrl':
      case 'control':
        modifiers.add(HotKeyModifier.control);
      case 'shift':
        modifiers.add(HotKeyModifier.shift);
      case 'alt':
        modifiers.add(HotKeyModifier.alt);
      case 'meta':
      case 'cmd':
      case 'win':
        modifiers.add(HotKeyModifier.meta);
    }
  }

  final key = _physicalKey(keyToken);
  if (key == null) return null;

  return HotKey(key: key, modifiers: modifiers, scope: HotKeyScope.system);
}

PhysicalKeyboardKey? _physicalKey(String token) {
  return switch (token.toLowerCase()) {
    'a' => PhysicalKeyboardKey.keyA,
    'b' => PhysicalKeyboardKey.keyB,
    'c' => PhysicalKeyboardKey.keyC,
    'd' => PhysicalKeyboardKey.keyD,
    'e' => PhysicalKeyboardKey.keyE,
    'f' => PhysicalKeyboardKey.keyF,
    'g' => PhysicalKeyboardKey.keyG,
    'h' => PhysicalKeyboardKey.keyH,
    'i' => PhysicalKeyboardKey.keyI,
    'j' => PhysicalKeyboardKey.keyJ,
    'k' => PhysicalKeyboardKey.keyK,
    'l' => PhysicalKeyboardKey.keyL,
    'm' => PhysicalKeyboardKey.keyM,
    'n' => PhysicalKeyboardKey.keyN,
    'o' => PhysicalKeyboardKey.keyO,
    'p' => PhysicalKeyboardKey.keyP,
    'q' => PhysicalKeyboardKey.keyQ,
    'r' => PhysicalKeyboardKey.keyR,
    's' => PhysicalKeyboardKey.keyS,
    't' => PhysicalKeyboardKey.keyT,
    'u' => PhysicalKeyboardKey.keyU,
    'v' => PhysicalKeyboardKey.keyV,
    'w' => PhysicalKeyboardKey.keyW,
    'x' => PhysicalKeyboardKey.keyX,
    'y' => PhysicalKeyboardKey.keyY,
    'z' => PhysicalKeyboardKey.keyZ,
    _ => null,
  };
}

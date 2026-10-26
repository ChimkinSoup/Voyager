import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// Gaia's rebindable keys (GAIA_HLD.md §9.1, §15.1): the composer's send,
/// and the global hotkeys the main instance registers.
enum GaiaKeybind {
  send('Send', 'Ctrl+Enter', global: false),
  small('Small floater', 'Ctrl+Alt+Space'),
  large('Large floater', 'Ctrl+Alt+Shift+Space'),
  // Unbound by default (§15.1).
  window('Gaia window', ''),
  region('Screenshot a region', 'Ctrl+Alt+S'),
  screen('Screenshot the screen', 'Ctrl+Alt+Shift+S'),
  selection('Quote the selection', 'Ctrl+Alt+Q'),
  pickUp('Pick up a selection', 'Ctrl+Alt+Shift+Q'),
  abort('Abort', 'Ctrl+Alt+Backspace');

  const GaiaKeybind(this.label, this.defaultCombo, {this.global = true});

  final String label;

  /// Empty for unbound.
  final String defaultCombo;

  /// A system-wide hotkey, which needs a modifier so it never takes over
  /// plain typing in other apps.
  final bool global;
}

/// [keybind]'s combo under [overrides] (the synced settings' `keybinds`);
/// empty when unbound.
String gaiaComboFor(GaiaKeybind keybind, Map<String, String> overrides) =>
    overrides[keybind.name] ?? keybind.defaultCombo;

/// A parsed combo such as `Ctrl+Alt+Space`.
class GaiaCombo {
  const GaiaCombo({
    required this.logical,
    required this.physical,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey logical;
  final PhysicalKeyboardKey physical;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  bool get hasModifier => control || alt || meta;

  /// For a shortcut inside Gaia, such as send.
  SingleActivator get activator => SingleActivator(
    logical,
    control: control,
    shift: shift,
    alt: alt,
    meta: meta,
  );

  /// For a system-wide hotkey.
  HotKey get hotKey => HotKey(
    key: physical,
    modifiers: [
      if (control) HotKeyModifier.control,
      if (alt) HotKeyModifier.alt,
      if (shift) HotKeyModifier.shift,
      if (meta) HotKeyModifier.meta,
    ],
    scope: HotKeyScope.system,
  );

  @override
  String toString() => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Win',
    _keys.entries.firstWhere((entry) => entry.value.$1 == logical).key,
  ].join('+');
}

/// The keys a combo can end on, by their name in a stored combo.
final Map<String, (LogicalKeyboardKey, PhysicalKeyboardKey)> _keys = {
  'Space': (LogicalKeyboardKey.space, PhysicalKeyboardKey.space),
  'Enter': (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
  'Backspace': (LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace),
  for (final (i, letter) in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').indexed)
    letter: (
      LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + i),
      _letters[i],
    ),
  for (final (i, digit) in '0123456789'.split('').indexed)
    digit: (
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i),
      _digits[i],
    ),
  for (final (i, key) in _functionKeys.indexed) 'F${i + 1}': key,
};

const _letters = [
  PhysicalKeyboardKey.keyA,
  PhysicalKeyboardKey.keyB,
  PhysicalKeyboardKey.keyC, //
  PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.keyE, PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG, PhysicalKeyboardKey.keyH, PhysicalKeyboardKey.keyI,
  PhysicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyK, PhysicalKeyboardKey.keyL,
  PhysicalKeyboardKey.keyM, PhysicalKeyboardKey.keyN, PhysicalKeyboardKey.keyO,
  PhysicalKeyboardKey.keyP, PhysicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyR,
  PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.keyT, PhysicalKeyboardKey.keyU,
  PhysicalKeyboardKey.keyV, PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.keyX,
  PhysicalKeyboardKey.keyY, PhysicalKeyboardKey.keyZ,
];

const _digits = [
  PhysicalKeyboardKey.digit0, PhysicalKeyboardKey.digit1, //
  PhysicalKeyboardKey.digit2, PhysicalKeyboardKey.digit3,
  PhysicalKeyboardKey.digit4, PhysicalKeyboardKey.digit5,
  PhysicalKeyboardKey.digit6, PhysicalKeyboardKey.digit7,
  PhysicalKeyboardKey.digit8, PhysicalKeyboardKey.digit9,
];

const _functionKeys = [
  (LogicalKeyboardKey.f1, PhysicalKeyboardKey.f1),
  (LogicalKeyboardKey.f2, PhysicalKeyboardKey.f2),
  (LogicalKeyboardKey.f3, PhysicalKeyboardKey.f3),
  (LogicalKeyboardKey.f4, PhysicalKeyboardKey.f4),
  (LogicalKeyboardKey.f5, PhysicalKeyboardKey.f5),
  (LogicalKeyboardKey.f6, PhysicalKeyboardKey.f6),
  (LogicalKeyboardKey.f7, PhysicalKeyboardKey.f7),
  (LogicalKeyboardKey.f8, PhysicalKeyboardKey.f8),
  (LogicalKeyboardKey.f9, PhysicalKeyboardKey.f9),
  (LogicalKeyboardKey.f10, PhysicalKeyboardKey.f10),
  (LogicalKeyboardKey.f11, PhysicalKeyboardKey.f11),
  (LogicalKeyboardKey.f12, PhysicalKeyboardKey.f12),
];

/// Null for an empty combo (unbound), or one this build can't read.
GaiaCombo? parseGaiaCombo(String combo) {
  final parts = combo.split('+').map((p) => p.trim()).toList();
  if (parts.isEmpty || parts.last.isEmpty) return null;
  final key = _keys.entries
      .where((entry) => entry.key.toLowerCase() == parts.last.toLowerCase())
      .firstOrNull
      ?.value;
  if (key == null) return null;
  final modifiers = {
    for (final part in parts.sublist(0, parts.length - 1)) part.toLowerCase(),
  };
  return GaiaCombo(
    logical: key.$1,
    physical: key.$2,
    control: modifiers.contains('ctrl'),
    shift: modifiers.contains('shift'),
    alt: modifiers.contains('alt'),
    meta: modifiers.contains('win'),
  );
}

/// The combo [event] presses, with the modifiers held; null for a modifier
/// alone or a key a combo can't end on.
GaiaCombo? gaiaComboFromEvent(KeyEvent event) {
  if (event is! KeyDownEvent) return null;
  final key = _keys.values
      .where((key) => key.$1 == event.logicalKey)
      .firstOrNull;
  if (key == null) return null;
  final keyboard = HardwareKeyboard.instance;
  return GaiaCombo(
    logical: key.$1,
    physical: key.$2,
    control: keyboard.isControlPressed,
    shift: keyboard.isShiftPressed,
    alt: keyboard.isAltPressed,
    meta: keyboard.isMetaPressed,
  );
}

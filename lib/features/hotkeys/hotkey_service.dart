import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/utils/hotkey_parser.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:win32/win32.dart';

/// The hotkeys another app held when they were last tried, so they do
/// nothing in Voyager for now. Settings shows a notice on each (BUG-034);
/// they are tried again whenever the window comes back to the foreground.
final unavailableHotkeysProvider = StateProvider<Set<QuickCaptureKind>>(
  (_) => const {},
);

abstract class HotkeyService {
  /// Registers the four hotkeys and returns the ones another app holds.
  Future<Set<QuickCaptureKind>> register({
    required String journalHotkey,
    required String todoHotkey,
    required String financeHotkey,
    required String reminderHotkey,
    required void Function(QuickCaptureKind kind) onHotkey,
  });

  /// Tries the hotkeys [register] found taken again, and returns the ones
  /// still taken.
  Future<Set<QuickCaptureKind>> retryTaken();

  Future<void> dispose();
}

class WindowsHotkeyService implements HotkeyService {
  final _keys = <HotKey>[];

  /// The combos another app held, waiting for [retryTaken].
  final _taken = <QuickCaptureKind, HotKey>{};
  void Function(QuickCaptureKind kind)? _onHotkey;

  @override
  Future<Set<QuickCaptureKind>> register({
    required String journalHotkey,
    required String todoHotkey,
    required String financeHotkey,
    required String reminderHotkey,
    required void Function(QuickCaptureKind kind) onHotkey,
  }) async {
    await dispose();
    _onHotkey = onHotkey;
    final combos = {
      QuickCaptureKind.journal: journalHotkey,
      QuickCaptureKind.todo: todoHotkey,
      QuickCaptureKind.finance: financeHotkey,
      QuickCaptureKind.reminder: reminderHotkey,
    };
    for (final MapEntry(key: kind, value: combo) in combos.entries) {
      final key = parseHotKey(combo);
      if (key == null) continue;
      if (_isTaken(key)) {
        _taken[kind] = key;
        continue;
      }
      await hotKeyManager.register(key, keyDownHandler: (_) => onHotkey(kind));
      _keys.add(key);
    }
    return {..._taken.keys};
  }

  @override
  Future<Set<QuickCaptureKind>> retryTaken() async {
    final onHotkey = _onHotkey;
    if (onHotkey == null) return const {};
    for (final MapEntry(key: kind, value: key) in [..._taken.entries]) {
      if (_isTaken(key)) continue;
      _taken.remove(kind);
      await hotKeyManager.register(key, keyDownHandler: (_) => onHotkey(kind));
      _keys.add(key);
    }
    return {..._taken.keys};
  }

  /// Whether another app holds [key]'s combo. The plugin drops
  /// `RegisterHotKey`'s result, so a taken combo would be registered silently
  /// dead. Probed by registering the combo for this thread and letting go of
  /// it straight away; Voyager's own keys were let go of by [dispose] first.
  static bool _isTaken(HotKey key) {
    const probeId = 0xBFFF;
    var modifiers = 0;
    for (final modifier in key.modifiers ?? const <HotKeyModifier>[]) {
      modifiers |= switch (modifier) {
        HotKeyModifier.alt => MOD_ALT,
        HotKeyModifier.control => MOD_CONTROL,
        HotKeyModifier.meta => MOD_WIN,
        HotKeyModifier.shift => MOD_SHIFT,
        _ => 0,
      };
    }
    // [parseHotKey] only makes letter keys, whose virtual-key code is the
    // capital letter's.
    final virtualKey = key.logicalKey.keyLabel.toUpperCase().codeUnitAt(0);
    if (RegisterHotKey(NULL, probeId, modifiers, virtualKey) == 0) return true;
    UnregisterHotKey(NULL, probeId);
    return false;
  }

  @override
  Future<void> dispose() async {
    for (final key in _keys) {
      await hotKeyManager.unregister(key);
    }
    _keys.clear();
    _taken.clear();
  }
}

class NoOpHotkeyService implements HotkeyService {
  @override
  Future<Set<QuickCaptureKind>> register({
    required String journalHotkey,
    required String todoHotkey,
    required String financeHotkey,
    required String reminderHotkey,
    required void Function(QuickCaptureKind kind) onHotkey,
  }) async => const {};

  @override
  Future<Set<QuickCaptureKind>> retryTaken() async => const {};

  @override
  Future<void> dispose() async {}
}

HotkeyService createHotkeyService() {
  return isWindows ? WindowsHotkeyService() : NoOpHotkeyService();
}

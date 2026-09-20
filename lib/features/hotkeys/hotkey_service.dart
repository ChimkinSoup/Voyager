import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/utils/hotkey_parser.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

abstract class HotkeyService {
  Future<void> register({
    required String journalHotkey,
    required String todoHotkey,
    required String financeHotkey,
    required String reminderHotkey,
    required void Function(QuickCaptureKind kind) onHotkey,
  });

  Future<void> dispose();
}

class WindowsHotkeyService implements HotkeyService {
  final _keys = <HotKey>[];

  @override
  Future<void> register({
    required String journalHotkey,
    required String todoHotkey,
    required String financeHotkey,
    required String reminderHotkey,
    required void Function(QuickCaptureKind kind) onHotkey,
  }) async {
    await dispose();
    final combos = {
      QuickCaptureKind.journal: journalHotkey,
      QuickCaptureKind.todo: todoHotkey,
      QuickCaptureKind.finance: financeHotkey,
      QuickCaptureKind.reminder: reminderHotkey,
    };
    for (final MapEntry(key: kind, value: combo) in combos.entries) {
      final key = parseHotKey(combo);
      if (key == null) continue;
      await hotKeyManager.register(key, keyDownHandler: (_) => onHotkey(kind));
      _keys.add(key);
    }
  }

  @override
  Future<void> dispose() async {
    for (final key in _keys) {
      await hotKeyManager.unregister(key);
    }
    _keys.clear();
  }
}

class NoOpHotkeyService implements HotkeyService {
  @override
  Future<void> register({
    required String journalHotkey,
    required String todoHotkey,
    required String financeHotkey,
    required String reminderHotkey,
    required void Function(QuickCaptureKind kind) onHotkey,
  }) async {}

  @override
  Future<void> dispose() async {}
}

HotkeyService createHotkeyService() {
  return isWindows ? WindowsHotkeyService() : NoOpHotkeyService();
}

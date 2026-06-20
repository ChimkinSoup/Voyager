import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/utils/hotkey_parser.dart';

abstract class HotkeyService {
  Future<void> register({
    required String journalHotkey,
    required String todoHotkey,
    required VoidCallback onJournal,
    required VoidCallback onTodo,
  });

  Future<void> dispose();
}

class WindowsHotkeyService implements HotkeyService {
  HotKey? _journalKey;
  HotKey? _todoKey;

  @override
  Future<void> register({
    required String journalHotkey,
    required String todoHotkey,
    required VoidCallback onJournal,
    required VoidCallback onTodo,
  }) async {
    await dispose();
    _journalKey = parseHotKey(journalHotkey);
    _todoKey = parseHotKey(todoHotkey);

    if (_journalKey != null) {
      await hotKeyManager.register(
        _journalKey!,
        keyDownHandler: (_) => onJournal(),
      );
    }
    if (_todoKey != null) {
      await hotKeyManager.register(_todoKey!, keyDownHandler: (_) => onTodo());
    }
  }

  @override
  Future<void> dispose() async {
    if (_journalKey != null) {
      await hotKeyManager.unregister(_journalKey!);
      _journalKey = null;
    }
    if (_todoKey != null) {
      await hotKeyManager.unregister(_todoKey!);
      _todoKey = null;
    }
  }
}

class NoOpHotkeyService implements HotkeyService {
  @override
  Future<void> register({
    required String journalHotkey,
    required String todoHotkey,
    required VoidCallback onJournal,
    required VoidCallback onTodo,
  }) async {}

  @override
  Future<void> dispose() async {}
}

HotkeyService createHotkeyService() {
  return isWindows ? WindowsHotkeyService() : NoOpHotkeyService();
}

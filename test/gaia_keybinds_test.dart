import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/features/gaia/gaia_keybinds.dart';

/// Gaia's rebindable keys (GAIA_HLD.md §9.1, §15.1).
void main() {
  test('every default reads back as itself', () {
    for (final keybind in GaiaKeybind.values) {
      if (keybind.defaultCombo.isEmpty) continue;
      expect(
        '${parseGaiaCombo(keybind.defaultCombo)}',
        keybind.defaultCombo,
        reason: keybind.name,
      );
    }
  });

  test('full screen and split are bound, without clashing', () {
    expect(gaiaComboFor(GaiaKeybind.fullScreen, const {}), 'Ctrl+Alt+Enter');
    expect(gaiaComboFor(GaiaKeybind.split, const {}), 'Ctrl+Alt+Shift+Enter');
    final bound = [
      for (final keybind in GaiaKeybind.values)
        if (keybind.defaultCombo.isNotEmpty) keybind.defaultCombo,
    ];
    expect(bound.toSet(), hasLength(bound.length));
  });

  test("no default is one of Voyager's own global hotkeys", () {
    const voyager = {
      'journal': defaultJournalHotkey,
      'to-do': defaultTodoHotkey,
      'finance': defaultFinanceHotkey,
      'reminder': defaultReminderHotkey,
      'calendar': defaultCalendarHotkey,
    };
    for (final keybind in GaiaKeybind.values) {
      if (!keybind.global || keybind.defaultCombo.isEmpty) continue;
      expect(
        gaiaHotkeyClash(keybind.defaultCombo, voyager),
        isNull,
        reason: keybind.name,
      );
    }
  });

  test("a clash with Voyager's hotkeys, however they were typed", () {
    const voyager = {'Quick transaction': 'ctrl + alt + f', 'Other': ''};
    expect(gaiaHotkeyClash('Ctrl+Alt+F', voyager), 'Quick transaction');
    expect(gaiaHotkeyClash('Ctrl+Alt+G', voyager), isNull);
  });

  test('send is Ctrl+Enter, so Enter and Shift+Enter stay newlines', () {
    final send = parseGaiaCombo(GaiaKeybind.send.defaultCombo)!;
    expect(send.activator.trigger, LogicalKeyboardKey.enter);
    expect(send.activator.control, isTrue);
    expect(send.activator.shift, isFalse);
    expect(GaiaKeybind.send.global, isFalse);
  });

  test('a combo as a system hotkey', () {
    final abort = parseGaiaCombo('ctrl+alt+backspace')!;
    expect(abort.hasModifier, isTrue);
    expect(abort.hotKey.physicalKey, PhysicalKeyboardKey.backspace);
    expect(abort.hotKey.modifiers, [
      HotKeyModifier.control,
      HotKeyModifier.alt,
    ]);
    expect(parseGaiaCombo('Shift+K')!.hasModifier, isFalse);
    expect('${parseGaiaCombo('Win+F5')}', 'Win+F5');
    expect('${parseGaiaCombo('Alt+7')}', 'Alt+7');
  });

  test('unbound or unreadable is null', () {
    expect(parseGaiaCombo(''), isNull);
    expect(parseGaiaCombo('Ctrl+'), isNull);
    expect(parseGaiaCombo('Ctrl+Pause'), isNull);
  });

  test('overrides win over defaults, empty meaning unbound', () {
    expect(gaiaComboFor(GaiaKeybind.small, const {}), 'Ctrl+Alt+Space');
    expect(gaiaComboFor(GaiaKeybind.window, const {}), '');
    expect(
      gaiaComboFor(GaiaKeybind.window, const {'window': 'Ctrl+Alt+G'}),
      'Ctrl+Alt+G',
    );
    expect(gaiaComboFor(GaiaKeybind.abort, const {'abort': ''}), '');
  });
}

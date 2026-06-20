import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/features/shell/shell_destinations.dart';

/// In-app only. Never registered with [hotkey_manager].
bool get supportsShellTabShortcuts =>
    isWindows || currentPlatform == VoyagerPlatform.other;

int nextShellTabIndex(int currentIndex, [int? count]) {
  final total = count ?? shellDestinations.length;
  return (currentIndex + 1) % total;
}

int previousShellTabIndex(int currentIndex, [int? count]) {
  final total = count ?? shellDestinations.length;
  return (currentIndex - 1 + total) % total;
}

/// True when shell tab shortcuts may run for the current [BuildContext].
bool shellTabShortcutsEnabled(BuildContext context) {
  final route = ModalRoute.of(context);
  final rootNav = Navigator.maybeOf(context, rootNavigator: true);
  return shellTabShortcutsEnabledForState(
    platformSupported: supportsShellTabShortcuts,
    routeIsCurrent: route?.isCurrent ?? false,
    rootNavigatorCanPop: rootNav?.canPop() ?? false,
  );
}

@visibleForTesting
bool shellTabShortcutsEnabledForState({
  required bool platformSupported,
  required bool routeIsCurrent,
  required bool rootNavigatorCanPop,
}) {
  if (!platformSupported) return false;
  if (!routeIsCurrent) return false;
  if (rootNavigatorCanPop) return false;
  return true;
}

@visibleForTesting
bool isShellTabShortcutEvent(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
  if (!HardwareKeyboard.instance.isControlPressed) return false;
  return event.logicalKey == LogicalKeyboardKey.tab;
}

@visibleForTesting
int shellTabDeltaForEvent(KeyEvent event) {
  return HardwareKeyboard.instance.isShiftPressed ? -1 : 1;
}

class NextShellTabIntent extends Intent {
  const NextShellTabIntent();
}

class PreviousShellTabIntent extends Intent {
  const PreviousShellTabIntent();
}

/// Wraps authenticated shell content with Ctrl+Tab / Ctrl+Shift+Tab navigation.
///
/// Uses a [HardwareKeyboard] handler so shortcuts keep working even when branch
/// switches leave no focused widget (Flutter's [Shortcuts] widget requires focus).
class ShellKeyboardShortcuts extends StatefulWidget {
  const ShellKeyboardShortcuts({
    super.key,
    required this.navigationShell,
    required this.child,
  });

  final StatefulNavigationShell navigationShell;
  final Widget child;

  static const Map<ShortcutActivator, Intent> shortcuts = {
    SingleActivator(LogicalKeyboardKey.tab, control: true):
        NextShellTabIntent(),
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
        PreviousShellTabIntent(),
  };

  @override
  State<ShellKeyboardShortcuts> createState() => _ShellKeyboardShortcutsState();
}

class _ShellKeyboardShortcutsState extends State<ShellKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    if (supportsShellTabShortcuts) {
      HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    }
  }

  @override
  void dispose() {
    if (supportsShellTabShortcuts) {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted || !isShellTabShortcutEvent(event)) return false;
    if (!shellTabShortcutsEnabled(context)) return false;

    _goToRelativeTab(shellTabDeltaForEvent(event));
    return true;
  }

  void _goToRelativeTab(int delta) {
    final count = shellDestinations.length;
    if (count == 0) return;

    final current = widget.navigationShell.currentIndex;
    final next = delta > 0
        ? nextShellTabIndex(current, count)
        : previousShellTabIndex(current, count);
    if (next != current) {
      widget.navigationShell.goBranch(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// Prevents in-app tab shortcuts from reaching the main shell while a popup is open.
class BlockShellTabShortcuts extends StatelessWidget {
  const BlockShellTabShortcuts({super.key, required this.child});

  final Widget child;

  static const Map<ShortcutActivator, Intent> _blockingShortcuts = {
    SingleActivator(LogicalKeyboardKey.tab, control: true):
        _BlockShellTabIntent(),
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
        _BlockShellTabIntent(),
  };

  @override
  Widget build(BuildContext context) {
    if (!supportsShellTabShortcuts) return child;

    return Shortcuts(
      shortcuts: _blockingShortcuts,
      child: Actions(
        actions: {_BlockShellTabIntent: DoNothingAction(consumesKey: true)},
        child: child,
      ),
    );
  }
}

class _BlockShellTabIntent extends Intent {
  const _BlockShellTabIntent();
}

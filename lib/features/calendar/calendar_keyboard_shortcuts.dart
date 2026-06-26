import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/utils/key_binding.dart';

/// True when a text field (or similar) owns focus — letter navigation keys must
/// not fire so the user can type normally.
@visibleForTesting
bool isTextInputFocused() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || !focus.hasFocus) return false;
  final context = focus.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

@visibleForTesting
bool calendarNavShortcutsEnabledForState({
  required bool routeIsCurrent,
  required bool rootNavigatorCanPop,
  required bool textInputFocused,
}) {
  if (!routeIsCurrent) return false;
  if (rootNavigatorCanPop) return false;
  if (textInputFocused) return false;
  return true;
}

bool calendarNavShortcutsEnabled(BuildContext context) {
  final route = ModalRoute.of(context);
  final rootNav = Navigator.maybeOf(context, rootNavigator: true);
  return calendarNavShortcutsEnabledForState(
    routeIsCurrent: route?.isCurrent ?? false,
    rootNavigatorCanPop: rootNav?.canPop() ?? false,
    textInputFocused: isTextInputFocused(),
  );
}

@visibleForTesting
int? calendarNavDeltaForEvent(
  KeyEvent event, {
  required String navigateLeftKey,
  required String navigateRightKey,
  required bool letterKeysEnabled,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;

  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) return -1;
  if (event.logicalKey == LogicalKeyboardKey.arrowRight) return 1;

  if (!letterKeysEnabled) return null;

  if (matchesKeyBinding(event, navigateLeftKey)) return -1;
  if (matchesKeyBinding(event, navigateRightKey)) return 1;

  return null;
}

/// In-app calendar period navigation (arrows + configurable letter keys).
///
/// Uses a [HardwareKeyboard] handler so navigation works even when no widget
/// inside the calendar tree has focus.
class CalendarKeyboardShortcuts extends StatefulWidget {
  const CalendarKeyboardShortcuts({
    super.key,
    required this.navigateLeftKey,
    required this.navigateRightKey,
    required this.onNavigate,
    required this.child,
  });

  final String navigateLeftKey;
  final String navigateRightKey;
  final ValueChanged<int> onNavigate;
  final Widget child;

  @override
  State<CalendarKeyboardShortcuts> createState() =>
      _CalendarKeyboardShortcutsState();
}

class _CalendarKeyboardShortcutsState extends State<CalendarKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (!calendarNavShortcutsEnabled(context)) return false;

    final delta = calendarNavDeltaForEvent(
      event,
      navigateLeftKey: widget.navigateLeftKey,
      navigateRightKey: widget.navigateRightKey,
      letterKeysEnabled: !isTextInputFocused(),
    );
    if (delta == null) return false;

    widget.onNavigate(delta);
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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
  required bool subtreeIsVisible,
}) {
  if (!routeIsCurrent) return false;
  if (rootNavigatorCanPop) return false;
  if (textInputFocused) return false;
  if (!subtreeIsVisible) return false;
  return true;
}

bool calendarNavShortcutsEnabled(BuildContext context) {
  final route = ModalRoute.of(context);
  final rootNav = Navigator.maybeOf(context, rootNavigator: true);
  return calendarNavShortcutsEnabledForState(
    routeIsCurrent: route?.isCurrent ?? false,
    rootNavigatorCanPop: rootNav?.canPop() ?? false,
    textInputFocused: isTextInputFocused(),
    subtreeIsVisible: subtreeIsVisible(context),
  );
}

/// Whether this widget's subtree is the one the user is actually looking at.
///
/// [routeIsCurrent] isn't enough on its own: the shell keeps every branch
/// mounted at once (see `ShellBranchContainer`), each with its own navigator,
/// so a hidden branch's page is still the current route *of that branch* — and
/// [HardwareKeyboard] handlers fire regardless of who's on screen. Without
/// this, an arrow key would drive every mounted calendar at once, silently
/// paging the ones the user can't see.
///
/// [TickerMode] is the signal the shell already flips per branch, and Flutter
/// disables it for offscreen routes too, so it covers a page being covered by
/// a pushed route as well. Read via [TickerMode.getValuesNotifier] rather than
/// [TickerMode.valuesOf] because this is called from a key handler, not a
/// build — the latter would register an inherited dependency outside of build.
@visibleForTesting
bool subtreeIsVisible(BuildContext context) =>
    TickerMode.getValuesNotifier(context).value.enabled;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

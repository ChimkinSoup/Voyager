import 'package:flutter/material.dart';

/// True when a text field (or similar) owns focus — letter/space navigation
/// keys must not fire so the user can type normally. Shared by any
/// [HardwareKeyboard]-based shortcut handler (calendar nav, Study grading).
bool isTextInputFocused() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || !focus.hasFocus) return false;
  final context = focus.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Whether this widget's subtree is the one the user is actually looking at.
///
/// A route being current isn't enough on its own when a shell keeps every
/// branch mounted at once, each with its own navigator — a hidden branch's
/// page is still the current route *of that branch*, and
/// [HardwareKeyboard] handlers fire regardless of who's on screen. Without
/// this, a shortcut would drive every mounted instance at once.
///
/// [TickerMode] is the signal such shells already flip per branch, and
/// Flutter disables it for offscreen routes too, so it covers a page being
/// covered by a pushed route as well. Read via
/// [TickerMode.getValuesNotifier] rather than [TickerMode.valuesOf] because
/// this is called from a key handler, not a build — the latter would
/// register an inherited dependency outside of build.
bool subtreeIsVisible(BuildContext context) =>
    TickerMode.getValuesNotifier(context).value.enabled;

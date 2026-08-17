import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';

/// Whether this app's own window still has the OS focus.
///
/// Switching to another app reaches the framework on **two** independent
/// channels, and the framework parks the primary focus on either of them:
///
///  * the app lifecycle message — [WidgetsBinding.lifecycleState] stops being
///    [AppLifecycleState.resumed] and `FocusManager` suspends the focused node
///    (`FocusManager._appLifecycleChange`), and
///  * a **view-focus** event — `View` responds to
///    [ViewFocusState.unfocused] by parking focus on the root scope
///    (`_ViewState.didChangeViewFocus`), with no lifecycle message involved.
///
/// Either can arrive first, and on Windows the view-focus event does: a widget
/// that consults only [WidgetsBinding.lifecycleState] sees that blur as "the
/// user left me" and tears its state down mid-switch. This collapses both
/// signals into one flag so callers can tell a window switch from a real focus
/// move inside the app.
class WindowFocusWatcher extends ChangeNotifier with WidgetsBindingObserver {
  WindowFocusWatcher._() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// The app-wide instance. Registered as a binding observer for the rest of
  /// the process the first time it is touched — the flag has to be current
  /// *before* a listener asks, which rules out installing the observer only
  /// while someone is listening.
  static final WindowFocusWatcher instance = WindowFocusWatcher._();

  bool _viewFocused = true;

  /// True while the window is in front of the user.
  ///
  /// A null lifecycle state — no message has arrived yet — reads as
  /// foreground: a focus loss that early is a real one.
  bool get hasFocus {
    if (!_viewFocused) return false;
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Single-window app, so any view gaining focus means this window has it.
  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    final focused = event.state == ViewFocusState.focused;
    if (focused == _viewFocused) return;
    _viewFocused = focused;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // [hasFocus] is derived, so there is nothing to store — listeners just
    // need telling that the answer may have changed.
    notifyListeners();
  }
}

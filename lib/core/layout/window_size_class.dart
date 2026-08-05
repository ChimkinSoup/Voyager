import 'package:flutter/widgets.dart';

/// Which of the two shell layouts the current window gets.
///
/// This is the *only* viewport-driven breakpoint in the app, and it exists to
/// pick between two deliberately separate compositions — the desktop shell
/// (persistent left rail, side-by-side panes) and the phone shell (bottom
/// navigation, one pane at a time). Everything finer than that stays
/// constraint-local: components adapt through their own `LayoutBuilder`
/// against the space they actually receive, which is how the rest of the
/// codebase already works.
///
/// Do not add steps here to tune a single widget. If a component needs to
/// change shape at some width, that is a `LayoutBuilder` inside the component.
enum WindowSizeClass {
  /// Phones in portrait, and any window narrower than a usable two-pane split.
  compact,

  /// The desktop window, tablets, and phones in landscape.
  expanded,
}

/// Material's compact/medium boundary. Below this a rail plus a content pane
/// leaves neither enough room to be worth having.
const double kCompactWidthBreakpoint = 600.0;

extension WindowSizeClassX on BuildContext {
  WindowSizeClass get windowSizeClass =>
      MediaQuery.sizeOf(this).width < kCompactWidthBreakpoint
      ? WindowSizeClass.compact
      : WindowSizeClass.expanded;

  /// True when the phone shell is in effect.
  bool get isCompactWidth => windowSizeClass == WindowSizeClass.compact;
}

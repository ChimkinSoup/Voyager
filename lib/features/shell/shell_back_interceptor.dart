import 'package:flutter/widgets.dart';

/// Gives a surface first refusal on the system Back gesture, before the shell
/// treats it as "leave this section".
///
/// The phone shell swaps between a section's sub-views in place rather than
/// pushing routes — the journal's editor replaces its entry list inside the
/// same branch, so the entry keeps its controllers, its debounced save timer
/// and its registration in [PendingFlushRegistry] instead of being torn down
/// and rebuilt on every open. That is the right trade for an editor, but it
/// leaves Navigator with nothing to pop, so Android Back would skip straight
/// past the open editor to another section.
///
/// A surface in that position registers here while its sub-view is showing and
/// returns `true` from the callback when it consumed the gesture.
///
/// Mirrors `PendingFlushRegistry`: a process-wide registry rather than an
/// inherited widget, because the shell that consults it sits above the branch
/// navigators and cannot see into them.
class ShellBackInterceptors {
  ShellBackInterceptors._();

  static final instance = ShellBackInterceptors._();

  final _handlers = <bool Function()>[];

  /// Registers [onBack] and returns the function that unregisters it. Call
  /// that in `dispose`, and whenever the sub-view closes by other means.
  VoidCallback register(bool Function() onBack) {
    _handlers.add(onBack);
    return () => _handlers.remove(onBack);
  }

  /// Offers the gesture to registered handlers, innermost first. Returns true
  /// once one of them consumes it.
  bool handle() {
    for (final handler in _handlers.reversed.toList(growable: false)) {
      if (handler()) return true;
    }
    return false;
  }
}

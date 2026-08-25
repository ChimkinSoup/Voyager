import 'package:flutter/widgets.dart';
import 'package:voyager/core/caps_lock/caps_lock_state.dart';

/// Publishes the user's "Caps Lock indicator" setting to every text field
/// below, with the platform gate already folded in.
///
/// Installed once at the app root beside [VimEnabledScope] and
/// [SnippetEnabledScope] (see `voyager_app.dart`), and read the same way —
/// through an inherited dependency, so flipping the switch in Settings reaches
/// every mounted field without any of them holding a Riverpod ref.
///
/// Fields read [CapsLockIndicatorScope.of], which is false on macOS and mobile
/// whatever the setting says: macOS draws its own Caps Lock glyph and a soft
/// keyboard has no lock key to report (CAPS_LOCK.md §2.2).
class CapsLockIndicatorScope extends InheritedWidget {
  CapsLockIndicatorScope({
    super.key,
    required bool enabled,
    required super.child,
  }) : enabled = enabled && capsLockIndicatorSupportsPlatform;

  /// Whether a field below may draw the badge, setting *and* platform.
  final bool enabled;

  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<CapsLockIndicatorScope>();
    return scope?.enabled ?? false;
  }

  @override
  bool updateShouldNotify(CapsLockIndicatorScope oldWidget) =>
      oldWidget.enabled != enabled;
}

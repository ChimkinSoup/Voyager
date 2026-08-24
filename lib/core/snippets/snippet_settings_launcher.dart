import 'package:flutter/widgets.dart';

/// Publishes "open the full snippets settings dialog" to the text-field stack.
///
/// The quick-add popover lives in `core/widgets` — it is opened from a text
/// field's context menu — but its "Manage all snippets…" action has to reach
/// `showSnippetsDialog`, which lives in `features/settings`. Nothing under
/// `lib/core` imports `lib/features`, so the app root hands the launcher down
/// instead, beside [SnippetEnabledScope] (see `voyager_app.dart`).
///
/// Absent (in a test that pumps a bare field, say), the action is simply not
/// offered.
class SnippetSettingsLauncher extends InheritedWidget {
  const SnippetSettingsLauncher({
    super.key,
    required this.open,
    required super.child,
  });

  final void Function(BuildContext context) open;

  static void Function(BuildContext context)? maybeOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SnippetSettingsLauncher>();
    return scope?.open;
  }

  @override
  bool updateShouldNotify(SnippetSettingsLauncher oldWidget) =>
      oldWidget.open != open;
}

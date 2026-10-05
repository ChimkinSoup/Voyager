import 'dart:async';

import 'package:flutter/widgets.dart';

/// Answers a one-shot reveal request (`reveal_request.dart`) for the Settings
/// section at [context]: clears it with [clearRequest], scrolls the section
/// into view within its tab's list, then runs [onShown] (to focus a field,
/// say).
///
/// After the frame: the request can't be cleared mid-build, and there is
/// nothing to scroll to before layout. Settings may also still be animating
/// to this tab — a reveal raised while it was open on another one — so this
/// waits for the tab view to settle and then scrolls only the list.
/// [Scrollable.ensureVisible] would scroll every ancestor, the moving tab view
/// included, whose viewport throws there (BUG-226); and a field focused
/// mid-animation scrolls itself into view through the same ancestors, so
/// [onShown] waits for the list's scroll too.
void revealSettingsSection(
  BuildContext context, {
  required VoidCallback clearRequest,
  VoidCallback? onShown,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    clearRequest();
    final list = Scrollable.maybeOf(context);
    if (list == null) return;
    final tabs = Scrollable.maybeOf(list.context)?.position.isScrollingNotifier;

    Future<void> scroll() async {
      if (!context.mounted || !list.mounted) return;
      final section = context.findRenderObject();
      if (section == null) return;
      await list.position.ensureVisible(
        section,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      if (context.mounted) onShown?.call();
    }

    if (tabs == null || !tabs.value) {
      unawaited(scroll());
      return;
    }
    void settled() {
      if (tabs.value) return;
      tabs.removeListener(settled);
      unawaited(scroll());
    }

    tabs.addListener(settled);
  });
}

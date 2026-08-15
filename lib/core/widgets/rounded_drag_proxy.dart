import 'package:flutter/material.dart';

/// A [ReorderableListView.proxyDecorator] that lifts the dragged row onto a
/// rounded, shadowed surface.
///
/// Flutter's default proxy is a square-cornered elevated [Material], which reads
/// as a hard rectangle torn out of a UI that is rounded everywhere else. Lists
/// that already decorate their own rows (and so never show the default) pass
/// their own decorator instead — this is for the ones that don't.
Widget roundedDragProxy(Widget child, int index, Animation<double> animation) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final theme = Theme.of(context);
      // Elevation rides the lift animation so the row rises into the drag
      // rather than snapping to its shadow.
      final lift = Curves.easeInOut.transform(animation.value);
      return Material(
        color: theme.colorScheme.surfaceContainerHigh,
        shadowColor: theme.colorScheme.shadow,
        elevation: 6 * lift,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    },
  );
}

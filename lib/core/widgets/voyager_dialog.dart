import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';

/// Opens [builder] via [showGeneralDialog] with a spring-shaped scale+fade
/// entrance instead of Material's fixed-curve default, honoring
/// reduced-motion. Use in place of [showDialog] for AlertDialog-style
/// prompts — the dialog content still owns its own background/material.
Future<T?> showVoyagerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = Colors.black54,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final reduced = VoyagerMotion.reduced(context);
      if (reduced) {
        return FadeTransition(opacity: animation, child: child);
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: VoyagerSpring.drawerCurve,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

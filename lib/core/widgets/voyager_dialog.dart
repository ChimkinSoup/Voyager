import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// Opens [builder] via [showGeneralDialog] with a spring-shaped scale+fade
/// entrance instead of Material's fixed-curve default, honoring
/// reduced-motion. Use in place of [showDialog] for AlertDialog-style
/// prompts — the dialog content still owns its own background/material.
///
/// Closing it leaves the caret where it was in the text field it was opened
/// from — see [_keepFieldSelection].
Future<T?> showVoyagerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,

  /// Defaults to the theme's [VoyagerColors.scrim].
  Color? barrierColor,
}) async {
  final restoreSelection = _keepFieldSelection();
  final result = await _showVoyagerDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
  );
  restoreSelection?.call();
  return result;
}

/// Remembers the focused text field's selection, and returns what puts it
/// back once the field has focus again.
///
/// Closing a dialog hands focus back to the field it was opened from, and a
/// one-line field on desktop selects all of its text when it regains focus,
/// so the next keystroke would replace the draft (BUG-069). Focus comes back
/// just after the dialog's future completes, so the selection is put back
/// from a focus listener, added after the field's own so it runs after that
/// select-all. If focus has not come back by the end of the next frame it
/// went somewhere else, and the listener is dropped rather than left to fire
/// on some later, unrelated focus.
VoidCallback? _keepFieldSelection() {
  final field = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  if (field == null) return null;
  final before = field.textEditingValue;
  final focusNode = field.widget.focusNode;
  final controller = field.widget.controller;

  void restore() {
    focusNode.removeListener(restore);
    if (!field.mounted || !focusNode.hasFocus) return;
    if (controller.text != before.text) return;
    controller.selection = before.selection;
  }

  return () {
    if (!field.mounted) return;
    if (focusNode.hasFocus) {
      restore();
      return;
    }
    focusNode.addListener(restore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (field.mounted) focusNode.removeListener(restore);
    });
  };
}

Future<T?> _showVoyagerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool barrierDismissible,
  required Color? barrierColor,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor ?? VoyagerColors.of(context).scrim,
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

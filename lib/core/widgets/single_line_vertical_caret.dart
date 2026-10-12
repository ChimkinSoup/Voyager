import 'package:flutter/widgets.dart';

/// Arrow Up/Down and Page Up/Down for a single-line field, done here instead
/// of by EditableText. Installed once at the app root, so it covers every
/// field, controller or not.
///
/// Flutter's handler asserts on any field whose text is not start-aligned:
/// `TextPainter.computeLineMetrics` returns a fresh list whenever the paint
/// offset is non-zero, so `VerticalCaretMovementRun.isValid` (an `identical`
/// check) is false from the moment the run starts. On one line the outcome
/// is fixed anyway — down goes to the end, up to the start — so this does
/// exactly that, extending the selection when Shift is held. Multi-line
/// fields are handed back to Flutter's own action.
///
/// Keyed on the base type: EditableText registers its line and page intents
/// as one overridable `_UpdateTextSelectionVerticallyAction<
/// DirectionalCaretMovementIntent>`, and an override is looked up by that
/// type argument, not by the intent's own type.
class SingleLineVerticalCaretAction
    extends ContextAction<DirectionalCaretMovementIntent> {
  /// The focused single-line field the key came from, or null when the key
  /// belongs to Flutter's own action.
  static EditableTextState? _singleLineField(BuildContext? context) {
    // Invoked from the focused EditableText's focus node, below its state.
    final state = context?.findAncestorStateOfType<EditableTextState>();
    return state?.widget.maxLines == 1 ? state : null;
  }

  /// Disabled while there is no selection to move, as Flutter's own action
  /// is, so the key falls through to whatever handles arrows above the field.
  @override
  bool isEnabled(
    DirectionalCaretMovementIntent intent, [
    BuildContext? context,
  ]) {
    final field = _singleLineField(context);
    if (field == null) {
      final fallback = callingAction;
      return fallback is ContextAction<DirectionalCaretMovementIntent>
          ? fallback.isEnabled(intent, context)
          : fallback?.isEnabled(intent) ?? false;
    }
    return field.widget.controller.selection.isValid;
  }

  @override
  Object? invoke(
    DirectionalCaretMovementIntent intent, [
    BuildContext? context,
  ]) {
    final field = _singleLineField(context);
    if (field == null) {
      final fallback = callingAction;
      return fallback is ContextAction<DirectionalCaretMovementIntent>
          ? fallback.invoke(intent, context)
          : fallback?.invoke(intent);
    }
    final controller = field.widget.controller;
    final target = TextPosition(
      offset: intent.forward ? controller.text.length : 0,
    );
    // Only extends a selection when the user is allowed to make one.
    controller.selection =
        intent.collapseSelection || !field.widget.selectionEnabled
        ? TextSelection.fromPosition(target)
        : controller.selection.extendTo(target);
    return null;
  }
}

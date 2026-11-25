import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_aurora_edge.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

/// The text box Gaia's cards edit in (a proposal's fields, a memory's
/// text): in Gaia's field fill and aurora edge, its label inside along the
/// top.
///
/// Two things differ from a plain [TextField], both about selecting nothing:
///
///  * Selection boxes are [ui.BoxWidthStyle.tight]. The desktop default,
///    `max`, runs every selected line's highlight out to the field's edge,
///    past where its text ends.
///  * A double or triple click in empty space past a line's end selects that
///    line's break, which is all Flutter finds there. Such a click is put back
///    to a caret, as if it had landed on the line's end.
class GaiaCardTextField extends StatefulWidget {
  const GaiaCardTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.labelText,
    this.maxLines = 1,
    this.style,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? labelText;
  final int maxLines;
  final TextStyle? style;

  @override
  State<GaiaCardTextField> createState() => _GaiaCardTextFieldState();
}

class _GaiaCardTextFieldState extends State<GaiaCardTextField> {
  /// The edge follows the focus, so one of its own when not given one.
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  /// Where the primary button last went down, or null if it wasn't a plain
  /// click (another button, or Shift held to extend a selection).
  Offset? _down;

  void _onDown(PointerDownEvent event) {
    _down =
        event.buttons == kPrimaryButton &&
            !HardwareKeyboard.instance.isShiftPressed
        ? event.position
        : null;
  }

  void _onUp(PointerUpEvent event) {
    final down = _down;
    _down = null;
    // A drag selects what it covers, whitespace or not.
    if (down == null || (event.position - down).distance > kTouchSlop) return;
    // After the event: a word selection can wait on the gesture arena, which
    // settles once every handler has seen this pointer up.
    scheduleMicrotask(() {
      if (!mounted) return;
      final controller = widget.controller;
      final selection = controller.selection;
      if (!selection.isValid || selection.isCollapsed) return;
      final selected = selection.textInside(controller.text);
      if (selected.trim().isEmpty && selected.contains('\n')) {
        controller.selection = TextSelection.collapsed(offset: selection.start);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onDown,
    onPointerUp: _onUp,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: gaiaFieldFill,
        borderRadius: BorderRadius.circular(GaiaRadius.row),
      ),
      child: GaiaAuroraEdge(
        focusNode: _focus,
        child: TextField(
          controller: widget.controller,
          focusNode: _focus,
          minLines: 1,
          maxLines: widget.maxLines,
          style: widget.style,
          selectionWidthStyle: ui.BoxWidthStyle.tight,
          decoration: InputDecoration(
            labelText: widget.labelText,
            isDense: true,
            // The box above is the fill and the aurora the edge.
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          ),
        ),
      ),
    ),
  );
}

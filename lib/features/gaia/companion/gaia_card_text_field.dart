import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The outlined text box Gaia's cards edit in (a proposal's fields, a
/// memory's text).
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
    this.labelText,
    this.maxLines = 1,
    this.style,
  });

  final TextEditingController controller;
  final String? labelText;
  final int maxLines;
  final TextStyle? style;

  @override
  State<GaiaCardTextField> createState() => _GaiaCardTextFieldState();
}

class _GaiaCardTextFieldState extends State<GaiaCardTextField> {
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
        controller.selection = TextSelection.collapsed(
          offset: selection.start,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onDown,
    onPointerUp: _onUp,
    child: TextField(
      controller: widget.controller,
      minLines: 1,
      maxLines: widget.maxLines,
      style: widget.style,
      selectionWidthStyle: ui.BoxWidthStyle.tight,
      decoration: InputDecoration(
        labelText: widget.labelText,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

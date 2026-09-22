import 'package:flutter/widgets.dart';

/// Keeps a field's whole text selected through a click that is meant to
/// select it: the click that focuses it, or one while [selectAllPending].
///
/// On desktop, Flutter moves the caret to the click as soon as the tap is
/// recognised — on mouse *down* — so a select-all restored from `onTap` (mouse
/// *up*) leaves the frames in between showing a bare caret, and the highlight
/// blinks out and back. Instead, the first selection change after the
/// pointer goes down is answered right there, inside the same notification,
/// so the collapsed selection is never painted.
class SelectAllOnClick extends StatefulWidget {
  const SelectAllOnClick({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.selectAllPending,
    required this.child,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool Function() selectAllPending;
  final Widget child;

  @override
  State<SelectAllOnClick> createState() => _SelectAllOnClickState();
}

class _SelectAllOnClickState extends State<SelectAllOnClick> {
  TextEditingController? _armed;

  void _arm() {
    _disarm();
    _armed = widget.controller..addListener(_reselect);
  }

  void _disarm() {
    _armed?.removeListener(_reselect);
    _armed = null;
  }

  void _reselect() {
    final controller = _armed!;
    _disarm();
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  @override
  void dispose() {
    _disarm();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (widget.focusNode.hasFocus && !widget.selectAllPending()) return;
        _arm();
      },
      onPointerUp: (_) => _disarm(),
      onPointerCancel: (_) => _disarm(),
      child: widget.child,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Invokes [onSubmit] when Enter is pressed and no text field has focus.
class EnterToSubmitScope extends StatelessWidget {
  const EnterToSubmitScope({
    super.key,
    required this.onSubmit,
    required this.child,
  });

  final VoidCallback onSubmit;
  final Widget child;

  bool _textFieldHasFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    return focus.context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          if (_textFieldHasFocus()) return KeyEventResult.ignored;
          onSubmit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

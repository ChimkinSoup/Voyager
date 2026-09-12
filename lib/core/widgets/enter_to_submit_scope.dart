import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';

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
        // The chord belongs to [CtrlEnterToSubmitScope], which is the outer
        // scope on several surfaces. Claiming it here would run this scope's
        // action — Close, on the search entry dialog — instead of the save
        // the chord means.
        if (isSubmitChord(event)) return KeyEventResult.ignored;
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

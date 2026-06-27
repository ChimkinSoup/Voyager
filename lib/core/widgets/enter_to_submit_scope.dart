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
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (_textFieldHasFocus()) return null;
              onSubmit();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether [event] is the submit chord: Ctrl+Enter, or Cmd+Enter on Apple
/// platforms.
///
/// Repeats count as well as the first press, so a held chord is claimed for
/// its whole length instead of typing newlines after the first one.
bool isSubmitChord(KeyEvent event) {
  if (event is KeyUpEvent) return false;
  final key = event.logicalKey;
  if (key != LogicalKeyboardKey.enter &&
      key != LogicalKeyboardKey.numpadEnter) {
    return false;
  }
  final keyboard = HardwareKeyboard.instance;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.iOS => keyboard.isMetaPressed,
    _ => keyboard.isControlPressed,
  };
}

/// Invokes [onSubmit] on Ctrl+Enter (Cmd+Enter on Apple platforms), including
/// while a text field inside [child] has focus — the one chord that commits a
/// form from a multiline field, where bare Enter is a newline.
///
/// Bare Enter is left alone: [EnterToSubmitScope] and field-level
/// `onSubmitted` own that key, so the two scopes nest without conflict.
class CtrlEnterToSubmitScope extends StatelessWidget {
  const CtrlEnterToSubmitScope({
    super.key,
    required this.onSubmit,
    this.autofocus = false,
    required this.child,
  });

  /// The surface's affirmative action. Prefer one that validates for itself
  /// over one gated on build-time state, which is only as fresh as the last
  /// frame. Null (a disabled action) still claims the chord, so it can't fall
  /// through to the focused field as a newline.
  final VoidCallback? onSubmit;

  /// Takes focus when the surface opens, for a surface with no text field to
  /// hold it: key events start at the focused node and bubble up, so with
  /// nothing focused below this scope the chord never reaches it. Leave false
  /// wherever a field autofocuses — this would claim the scope's autofocus
  /// first and the field's would be ignored.
  final bool autofocus;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Only listens unless asked to hold focus, and never a Tab stop.
      canRequestFocus: autofocus,
      autofocus: autofocus,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (!isSubmitChord(event)) return KeyEventResult.ignored;
        if (event is KeyDownEvent) onSubmit?.call();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

/// Suppression flag for the "what did this keystroke mean" rules an editor
/// applies to an incoming [TextEditingValue] — auto-pair deletion, backspace
/// outdent and the like.
///
/// Those rules classify an edit by comparing the incoming text and caret
/// against the current ones, which only identifies a keystroke when the edit
/// *came from* one. Vim's `x` on the last character of a line writes the same
/// pair a backspace one place to the right would: the character is cut and the
/// caret is then clamped back onto the line, so both the text and the caret
/// land one earlier. Read as a backspace, `x` on the closing half of an
/// auto-closed pair took both halves and parked the caret past the line's last
/// character, where every later `x` was a no-op; `x` inside a line's indent ate
/// a whole tab stop.
///
/// The same misreading catches undo and redo, whose restored value is no more
/// a keystroke than Vim's is: Ctrl+Z over a space typed into a line's indent
/// handed back the text from before the space, and the outdent rule took that
/// for a backspace and dropped the indent to the tab stop below. Flutter's
/// [UndoHistory] asserts the restored value sticks, so in debug the rewrite
/// also tripped that assert.
///
/// A programmatic writer wraps its write in [suppressTypingRewrites] to say the
/// value is already the finished edit; [TypingRewriteUndoGuard] does it for the
/// restores that arrive as an intent rather than a call.
library;

import 'package:flutter/widgets.dart';

/// Depth of programmatic writes currently in progress. Nested because a write
/// may pass through more than one guarded path.
int _suppressTypingRewrites = 0;

/// Runs [body] with keystroke interpretation suppressed.
T suppressTypingRewrites<T>(T Function() body) {
  _suppressTypingRewrites++;
  try {
    return body();
  } finally {
    _suppressTypingRewrites--;
  }
}

/// Whether the value being written is a finished edit rather than a keystroke.
bool get typingRewritesSuppressed => _suppressTypingRewrites > 0;

/// Ancestor [Actions] override so Ctrl+Z / Ctrl+Y (and every other
/// [UndoTextIntent] / [RedoTextIntent] source) restore through
/// [suppressTypingRewrites].
///
/// Wrap every [TextField] whose controller rewrites incoming values by
/// keystroke shape. Vim's own `u` / `<C-r>` call the undo controller directly
/// and guard the call there instead.
class TypingRewriteUndoGuard extends StatelessWidget {
  const TypingRewriteUndoGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        UndoTextIntent: _RestoringUndoAction(),
        RedoTextIntent: _RestoringRedoAction(),
      },
      child: child,
    );
  }
}

final class _RestoringUndoAction extends Action<UndoTextIntent> {
  @override
  Object? invoke(UndoTextIntent intent) {
    return suppressTypingRewrites(() => callingAction?.invoke(intent));
  }
}

final class _RestoringRedoAction extends Action<RedoTextIntent> {
  @override
  Object? invoke(RedoTextIntent intent) {
    return suppressTypingRewrites(() => callingAction?.invoke(intent));
  }
}

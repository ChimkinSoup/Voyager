import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/typing_rewrites.dart';

/// The undo history of a text field another device's text can arrive in
/// while it is open: the journal and dream bodies and a task's notes.
///
/// Flutter's own history records whatever the controller is set to, so a
/// remote merge became the newest undo step, and the steps before it held
/// texts without the other device's characters: Ctrl+Z took the other
/// device's text out and the field's next save deleted it everywhere
/// (BUG-237). Here a merge goes in through [applyRemote], which is not a step
/// and carries the other device's change into every step already recorded, so
/// undo and redo only ever move this device's own edits.
///
/// Records like Flutter's history does — a step per pause of
/// [_throttle] in the typing — and is driven the same ways: Ctrl+Z / Ctrl+Y
/// through [MergeAwareUndoScope], Vim's `u` / `<C-r>` and a snippet undo
/// through [undo] / [redo], which this overrides rather than forwarding to the
/// field's own history.
class MergeAwareUndoController extends UndoHistoryController {
  MergeAwareUndoController(this._text) {
    _text.addListener(_handleTextChanged);
    _steps.add(_text.value);
  }

  final TextEditingController _text;

  static const _throttle = Duration(milliseconds: 500);

  final _steps = <TextEditingValue>[];
  var _index = 0;
  Timer? _pending;
  var _quiet = false;

  /// Applies a restored step as the user's own edit, so the field's
  /// `onChanged` records and saves it like typing. Set by the field.
  void Function(TextEditingValue value)? applyAsEdit;

  /// Puts [merged] — another device's change, already merged into the
  /// field's text — into the field without making it an undo step, and folds
  /// the same change into every step recorded so far.
  void applyRemote(
    TextEditingValue merged, {
    required String previousRemoteText,
    required String remoteText,
  }) {
    // The step the field shows becomes exactly what it shows now: derived like
    // the others, it could differ from [merged], and an undo then redo put
    // that text back and saved it everywhere.
    final showing = _text.text == _steps[_index].text;
    final insert = _leftmostInsertion(previousRemoteText, remoteText);
    for (var i = 0; i < _steps.length; i++) {
      final step = _steps[i];
      final text =
          insert != null &&
              step.text.startsWith(previousRemoteText.substring(0, insert.$1))
          ? step.text.replaceRange(insert.$1, insert.$1, insert.$2)
          : TextDeltaInjector.injectRemoteDelta(
              localText: step.text,
              oldRemoteText: previousRemoteText,
              newRemoteText: remoteText,
            );
      if (text == step.text) continue;
      _steps[i] = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: TextDeltaInjector.adjustedSelection(
            selection: step.selection.baseOffset,
            before: step.text,
            after: text,
          ),
        ),
      );
    }
    if (showing) _steps[_index] = merged;
    _quietly(() => _text.value = merged);
  }

  /// [after] as [before] with one run inserted: the offset and the run, slid
  /// as far left as the text allows, or null for any other change.
  ///
  /// "Base" → "Bedit-Base" reads as "edit-B" after the shared "B" when the two
  /// are diffed from the front, which an older, shorter step (one without that
  /// "B") can't take: put in at 0 it garbled the step. Slid left it is "Bedit-"
  /// at 0, which lands right in every step that shares the text before it.
  static (int, String)? _leftmostInsertion(String before, String after) {
    if (after.length <= before.length) return null;
    var prefix = 0;
    while (prefix < before.length &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    final run = after.length - before.length;
    if (after.substring(prefix + run) != before.substring(prefix)) return null;
    var at = prefix;
    var inserted = after.substring(at, at + run);
    while (at > 0 && before[at - 1] == inserted[inserted.length - 1]) {
      inserted = before[at - 1] + inserted.substring(0, inserted.length - 1);
      at--;
    }
    return (at, inserted);
  }

  /// Starts over from the field's current text: another document was loaded
  /// into it, and nothing before that is this document's to undo.
  void reset() {
    _pending?.cancel();
    _steps
      ..clear()
      ..add(_text.value);
    _index = 0;
    _report();
  }

  void _handleTextChanged() {
    if (_quiet) return;
    final value = _text.value;
    // As Flutter's history: composing text and caret moves are not steps.
    if (!value.composing.isCollapsed) return;
    if (_pending?.isActive ?? false) return;
    if (value.text == _steps[_index].text) return;
    _pending = Timer(_throttle, _commit);
    _report();
  }

  void _commit() {
    final value = _text.value;
    if (value.text == _steps[_index].text) {
      _report();
      return;
    }
    _steps
      ..removeRange(_index + 1, _steps.length)
      ..add(value);
    _index = _steps.length - 1;
    _report();
  }

  @override
  void undo() {
    if (_pending?.isActive ?? false) {
      // Typing not yet a step goes back to the last one, as in Flutter.
      _pending!.cancel();
      _commitWithoutStep();
      _restore(_steps[_index]);
      return;
    }
    if (_index == 0) return;
    _index--;
    _restore(_steps[_index]);
  }

  @override
  void redo() {
    if (_index >= _steps.length - 1) return;
    _index++;
    _restore(_steps[_index]);
  }

  /// Drops the redo steps a fresh edit makes unreachable.
  void _commitWithoutStep() {
    _steps.removeRange(_index + 1, _steps.length);
  }

  void _restore(TextEditingValue value) {
    // The same suspensions the field's own undo runs under — see
    // [ListEditingUndoGuard] and [TypingRewriteUndoGuard].
    _quietly(
      () => suppressListEditingWrites(
        () => suppressTypingRewrites(() {
          final apply = applyAsEdit;
          if (apply != null) {
            apply(value);
          } else {
            _text.value = value;
          }
        }),
      ),
    );
    _report();
  }

  void _quietly(VoidCallback body) {
    _quiet = true;
    try {
      body();
    } finally {
      _quiet = false;
    }
  }

  void _report() {
    super.value = UndoHistoryValue(
      canUndo: _index > 0 || (_pending?.isActive ?? false),
      canRedo: _index < _steps.length - 1,
    );
  }

  /// Ignored: the field's own [UndoHistory] reports its stack here too, and
  /// that one doesn't know about merges. [_report] sets the real value.
  @override
  set value(UndoHistoryValue newValue) {}

  @override
  void dispose() {
    _pending?.cancel();
    _text.removeListener(_handleTextChanged);
    super.dispose();
  }
}

/// Sends Ctrl+Z / Ctrl+Y (and every other [UndoTextIntent] /
/// [RedoTextIntent]) in the field below to [controller] instead of the field's
/// own history. Must be the nearest such override above the field.
class MergeAwareUndoScope extends StatelessWidget {
  const MergeAwareUndoScope({
    super.key,
    required this.controller,
    required this.child,
  });

  final MergeAwareUndoController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        UndoTextIntent: CallbackAction<UndoTextIntent>(
          onInvoke: (_) => controller.undo(),
        ),
        RedoTextIntent: CallbackAction<RedoTextIntent>(
          onInvoke: (_) => controller.redo(),
        ),
      },
      child: child,
    );
  }
}

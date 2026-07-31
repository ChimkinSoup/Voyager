import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/widgets/spell_check_popup.dart';

/// Whether a field configured with these params should get spellcheck.
/// Covers `maxLines: null` (unbounded), which the widgets' own
/// `alignLabelToTop: expands || (maxLines ?? 1) > 1` heuristic misses.
bool isMultilineField({required bool expands, int? maxLines, int? minLines}) =>
    expands || minLines != null || maxLines == null || maxLines > 1;

VoyagerSpellCheckService readVoyagerSpellCheckService(BuildContext context) {
  return ProviderScope.containerOf(
    context,
    listen: false,
  ).read(voyagerSpellCheckServiceProvider);
}

/// Builds the shared [SpellCheckConfiguration] backed by
/// [voyagerSpellCheckServiceProvider]. A one-time `read` (not `watch`) is
/// correct: the service is a stable singleton whose internal word sets
/// mutate in place, so the field never needs to rebuild when the
/// dictionary/custom words change — the next spellcheck pass just sees the
/// updated data automatically.
SpellCheckConfiguration buildVoyagerSpellCheckConfiguration(
  BuildContext context,
) {
  return SpellCheckConfiguration(
    spellCheckService: readVoyagerSpellCheckService(context),
    spellCheckSuggestionsToolbarBuilder: voyagerSpellCheckContextMenuBuilder,
    // The visible squiggle is painted separately by SpellCheckSquiggleLayer,
    // which can apply a narrower "hide only while actively being typed" rule
    // instead of Flutter's own "hide whenever the cursor is anywhere inside
    // the word" rule (project_flutter_spellcheck_freeze memory, bug 4). An
    // empty style here is a deliberate no-op — TextStyle.merge only
    // overrides non-null fields, so merging this onto the real text style
    // leaves it unchanged. It must still be non-null: EditableText asserts
    // misspelledTextStyle is set whenever spellCheckService is.
    misspelledTextStyle: const TextStyle(),
  );
}

/// EditableText only ever calls [SpellCheckService] in response to real
/// keyboard/IME input (see `_formatAndSetValue` in Flutter's
/// editable_text.dart) — never on mount, and never when a controller's text
/// is set programmatically (e.g. loading a different journal entry into a
/// reused controller). That leaves squiggles stale/missing until the user's
/// next real keystroke.
///
/// This paints fresh results immediately by writing directly to
/// [EditableTextState.spellCheckResults] (public API) and calling its own
/// [State.setState] to trigger a repaint — deliberately NOT going through
/// [EditableTextState.userUpdateTextEditingValue]/the controller, since that
/// path also fires the field's `onChanged` (used by callers like the journal
/// editor to mark entries dirty and schedule autosave/sync) even when the
/// text hasn't actually changed.
///
/// Only call this when [focusNode] is unfocused — a focused field can only
/// have gotten new text via real typing, which Flutter already spellchecks
/// on its own; re-running here too would double the per-keystroke cost we
/// just finished bounding (see project_flutter_spellcheck_freeze memory).
void forceSpellCheckDisplay({
  required BuildContext context,
  required GlobalKey<State<TextField>> fieldKey,
  required FocusNode focusNode,
}) {
  if (focusNode.hasFocus) return;
  final editableState = _editableTextStateOf(fieldKey);
  if (editableState == null) return;
  paintSpellCheckResultsNow(context, editableState);
}

/// Same repaint as [forceSpellCheckDisplay], for callers that already hold a
/// genuine [EditableTextState] (e.g. [SpellCheckPopup], which gets one from
/// [TextField.contextMenuBuilder]) and don't need the focus-gating or the
/// `dynamic` reach into [TextField]'s private state.
void paintSpellCheckResultsNow(
  BuildContext context,
  EditableTextState editableState,
) {
  final text = editableState.textEditingValue.text;
  if (text.isEmpty) return;
  final suggestions = readVoyagerSpellCheckService(context).checkTextSync(text);
  // setState is @protected — there's no public "repaint spellcheck now" API
  // on EditableTextState, and the alternative (userUpdateTextEditingValue)
  // has the onChanged side effect this function exists to avoid. Safe here:
  // we're only ever called with a GlobalKey/EditableTextState we were handed
  // or created ourselves.
  // ignore: invalid_use_of_protected_member
  editableState.setState(() {
    editableState.spellCheckResults = SpellCheckResults(text, suggestions);
  });
}

/// [TextField]'s State class (and its `editableTextKey` field, which holds
/// the [EditableTextState] we need) is private to Flutter's material
/// library, with no public constructor param to inject our own key — so
/// this reaches it via `dynamic`. `editableTextKey` itself is a public,
/// unprefixed field (Dart privacy is name-based, not class-based), just
/// declared on a class we can't name. If a future Flutter version renames or
/// removes it, this fails closed (returns null, caught below) rather than
/// crashing — the field just falls back to today's behavior of only
/// spellchecking on the next real keystroke.
EditableTextState? _editableTextStateOf(GlobalKey<State<TextField>> fieldKey) {
  final state = fieldKey.currentState;
  if (state == null) return null;
  try {
    final dynamic dynamicState = state;
    final key = dynamicState.editableTextKey;
    return key is GlobalKey<EditableTextState> ? key.currentState : null;
  } catch (_) {
    return null;
  }
}

/// Keeps the field scrolled so its cursor stays visible, even when the
/// controller was mutated by writing `.value =` directly rather than through
/// [EditableTextState.userUpdateTextEditingValue].
///
/// Real keystrokes go through `updateEditingValue`, which unconditionally
/// schedules Flutter's own "scroll the caret into view" step — but only for
/// that one call. This app's list-editing helpers (`applyListEditing`,
/// `handleListTab`, `handleListBackspace` in list_text_editing.dart) run
/// inside `onChanged` and write `controller.value =` directly whenever a
/// list needs renumbering, exactly the "programmatic changes... do not
/// trigger [scroll-into-view]" case EditableText's own source comments
/// warn about. Once that starts happening on a meaningful fraction of
/// keystrokes (any document using `-`/`1.` list lines), the field's
/// internal scroll position stops following the cursor entirely — new
/// lines keep appearing below the fold with no further auto-scroll, which
/// also freezes [SpellCheckSquiggleLayer]'s scroll-synced overlay (it
/// mirrors this same [ScrollController]) at whatever offset the last real
/// scroll left it at.
///
/// Safe to call after every controller change: [EditableTextState
/// .bringIntoView] is a no-op if the cursor is already on screen.
void bringCursorIntoView({required GlobalKey<State<TextField>> fieldKey}) {
  final editableState = _editableTextStateOf(fieldKey);
  if (editableState == null) {
    debugPrint('[bringCursorIntoView] no editableState');
    return;
  }
  final selection = editableState.textEditingValue.selection;
  if (!selection.isValid) {
    debugPrint('[bringCursorIntoView] invalid selection $selection');
    return;
  }
  debugPrint('[bringCursorIntoView] calling bringIntoView(${selection.extent})');
  editableState.bringIntoView(selection.extent);
}

/// Wraps a spellcheck-enabled field's [TextField] so a right-click always
/// moves the cursor to the clicked word before Flutter decides whether to
/// show a context menu.
///
/// Flutter's own secondary-tap handling
/// (`TextSelectionGestureDetectorBuilder.onSecondaryTap`) only repositions
/// the cursor when the field doesn't already have focus — once you're
/// actively editing (the common case), right-clicking a different word
/// leaves the cursor wherever it was. [voyagerSpellCheckContextMenuBuilder]
/// looks up the flagged word at the *cursor*, so that stale cursor makes
/// right-clicking a misspelled word silently show nothing. This forces the
/// same `RenderEditable.selectWord` Flutter already runs unconditionally for
/// long-press, on every secondary-button pointer-down. A raw [Listener] is
/// used (not a [GestureDetector]) so it observes the event without
/// competing with the field's own gesture recognizers.
Widget wrapWithSecondaryTapWordSelect({
  required GlobalKey<State<TextField>> fieldKey,
  required Widget child,
}) {
  return Listener(
    onPointerDown: (event) {
      if (event.buttons & kSecondaryMouseButton == 0) return;
      final editableState = _editableTextStateOf(fieldKey);
      if (editableState == null) return;
      editableState.renderEditable
        ..handleSecondaryTapDown(
          TapDownDetails(globalPosition: event.position, kind: event.kind),
        )
        ..selectWord(cause: SelectionChangedCause.tap);
    },
    child: child,
  );
}

/// Shared `contextMenuBuilder` for spellcheck-enabled fields: shows
/// [SpellCheckPopup] when the cursor is on a flagged word, otherwise
/// preserves the app's suppressed native-context-menu behavior.
Widget voyagerSpellCheckContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final cursor = editableTextState.textEditingValue.selection.extentOffset;
  final span = editableTextState.findSuggestionSpanAtCursorIndex(cursor);
  if (span == null) return const SizedBox.shrink();
  return SpellCheckPopup(editableTextState: editableTextState, span: span);
}

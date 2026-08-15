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

/// Padding that lines a text overlay (the squiggle layer, a tag-highlight
/// layer) up with the glyphs of a [TextField] laid out with [contentPadding].
///
/// Material 3's InputDecorator insets a field's text horizontally by an extra
/// "input gap" on top of its content padding: an [OutlineInputBorder]'s own
/// `gapPadding` — 4.0 unless the border says otherwise — or a flat 4.0 for any
/// other border that `isOutline` or any field with `filled: true`
/// (`_kInputExtraPadding`, input_decorator.dart). The gap comes from the
/// *state-resolved* border, so a field can pick it up on focus alone.
///
/// An overlay is just a [Padding] around a [Text]: it gets none of that, and
/// paints [gap] pixels left of the glyphs it belongs to unless it adds the
/// same inset here. Fields that take the zero-gap path — a borderless,
/// unfilled field, or one whose outline sets `gapPadding: 0` — should use
/// their content padding directly instead.
EdgeInsets withInputGap(EdgeInsets contentPadding, {double gap = 4.0}) =>
    contentPadding + EdgeInsets.symmetric(horizontal: gap);

/// The vertical counterpart of [withInputGap].
///
/// InputDecorator lays its text out at `contentPadding.top +
/// visualDensity.baseSizeAdjustment.dy / 2` (`topInputBaseline`,
/// input_decorator.dart) and sizes the content box to
/// `contentPadding.vertical + inputHeight + densityOffset.dy` — the full
/// density offset, half taken off each side. Voyager leaves
/// `decoration.visualDensity` and [ThemeData.visualDensity] unset, so both
/// resolve to [VisualDensity.defaultDensityForPlatform]: −4px per side on
/// desktop (`compact`), 0 on mobile (`standard`).
///
/// An overlay padded with the raw content padding therefore starts that many
/// pixels *below* the glyphs it belongs to, and is that many pixels *shorter*
/// than the content box. The shortfall clips the last line of anything the
/// overlay paints — a Vim block caret, a squiggle, a `#tag` pill. Pass the
/// density the field's decorator will resolve — [ThemeData.visualDensity] —
/// not a constant, so the overlay follows the text onto a platform with a
/// different density.
///
/// The shift is negative, so [contentPadding] has to be at least that deep
/// on both sides for the result to stay a valid [Padding]; every field in
/// the app pads by 6 or more.
EdgeInsets withDensityShift(EdgeInsets contentPadding, VisualDensity density) {
  final shift = density.baseSizeAdjustment.dy / 2.0;
  return contentPadding.copyWith(
    top: contentPadding.top + shift,
    bottom: contentPadding.bottom + shift,
  );
}

/// The strip [RenderEditable] keeps clear for the caret, which it takes out of
/// the width it *wraps the text at* — not just out of where it may draw.
///
/// `_layoutText` lays a field's paragraph out at `constraints.maxWidth -
/// (_kCaretGap + cursorWidth)`, a 1px gap plus the caret itself
/// (editable.dart), so the text wraps a few pixels short of the content box.
/// An overlay is a plain [Padding] around a paragraph of its own and gets
/// those pixels back: wherever a word boundary happens to fall inside the
/// strip it fits one word more on that line than the field does, and from
/// there down every mark it paints is a word out of step with the glyphs
/// underneath — squiggles under the wrong words, `#tag` pills and Vim search
/// highlights beside them, and a Vim block caret that skips over a word the
/// user can plainly see.
///
/// Taken off the right in either text direction, matching RenderEditable:
/// it shrinks the layout width and paints the paragraph from the content box's
/// left edge regardless.
///
/// [cursorWidth] has to be the width the field's own [TextField.cursorWidth]
/// resolves to — Vim's block caret is several times the 2.0 default, which is
/// why the misalignment is so much worse in Normal mode.
EdgeInsets withCaretMargin(
  EdgeInsets contentPadding, {
  double cursorWidth = 2.0,
}) => contentPadding.copyWith(right: contentPadding.right + 1.0 + cursorWidth);

/// Smallest line-height multiplier that leaves room for the misspelling
/// squiggle under a line of [AppFonts.family] text.
///
/// Measured on Iosevka Aile, in em (size-independent, since every term scales
/// with `fontSize`): ascenders reach 0.769em above the baseline, and the
/// squiggle — the font's wavy underline plus
/// [SpellCheckSquiggleLayer.descenderClearance] — bottoms out 0.19em below
/// it. A line has to be taller than 0.769 + 0.19 = 0.96em before one line's
/// squiggle starts being drawn on top of the next line's letters; 1.05 clears
/// it by 0.09em (1.5px at the 16px `bodyLarge`). There is not much room left
/// under this — 1.0 leaves well under a pixel, close enough to touching that
/// hinting or a fractional device pixel ratio could close it.
///
/// Spellchecked fields nowhere near this floor (the 1.35 of `bodyLarge`, the
/// 1.45 of `bodySmall`) are left exactly as they were.
const double kMinSquiggleLineHeight = 1.05;

/// Raises [style]'s line height to [kMinSquiggleLineHeight] if it is set
/// tighter than that, so a spellcheck-enabled field's squiggles stay inside
/// their own lines.
///
/// Must be applied to the style *before* it is handed to both the [TextField]
/// and its [SpellCheckSquiggleLayer] (and to any [StrutStyle] derived from
/// it): the overlay only lines up with the real text while the two lay out
/// identically, so this is a property of the field's text, not something the
/// overlay could compensate for on its own.
///
/// A null [TextStyle.height] is left alone — that means "use the font's own
/// line height", which is where the font's underline metrics come from in the
/// first place, so it always has the room by construction. Only an explicit
/// override can squeeze the line tighter than the font intended.
TextStyle withSquiggleRoom(TextStyle style) {
  final height = style.height;
  if (height == null || height >= kMinSquiggleLineHeight) return style;
  return style.copyWith(height: kMinSquiggleLineHeight);
}

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
  final editableState = editableTextStateOf(fieldKey);
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
EditableTextState? editableTextStateOf(GlobalKey<State<TextField>> fieldKey) {
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
  final editableState = editableTextStateOf(fieldKey);
  if (editableState == null) {
    return;
  }
  final selection = editableState.textEditingValue.selection;
  if (!selection.isValid) {
    return;
  }
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
      final editableState = editableTextStateOf(fieldKey);
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
  final text = editableTextState.textEditingValue.text;
  final hydrated = readVoyagerSpellCheckService(context)
      .hydrateSuggestions(text, span);
  return SpellCheckPopup(editableTextState: editableTextState, span: hydrated);
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/spellcheck/autocorrect_engine.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/prose_markup.dart';

/// A correction that just landed, for the layer that flashes it
/// (AUTOCORRECT.md §9).
@immutable
class AutocorrectFlash {
  const AutocorrectFlash({required this.range, required this.serial});

  /// The corrected word's span in the field's *current* text.
  final TextRange range;

  /// Distinguishes one correction from the next when both cover the same
  /// span — fixing the same typo twice has to restart the fade, and a
  /// [ValueNotifier] drops a publish that compares equal to the last one.
  final int serial;

  @override
  bool operator ==(Object other) =>
      other is AutocorrectFlash &&
      other.range == range &&
      other.serial == serial;

  @override
  int get hashCode => Object.hash(range, serial);
}

/// Conservative autocorrect for a single focused field.
///
/// Created per eligible field by `VimTextScope`, beside [SnippetSession] and
/// on the same terms: it reads keys from the scope's ancestor [Focus] and
/// writes through the field's [EditableTextState]. It runs with Vim switched
/// off, and with Vim on only in Insert (AUTOCORRECT.md §4.1).
///
/// ### Shape of the hot path
/// This sits on the keystroke path of every prose field in the app, so the
/// ordinary character — a letter, in the middle of a word — has to be nearly
/// free. It costs a boundary-character test and, for a word character, one
/// walk over the token being typed. Only a **boundary** keystroke goes
/// further, and only after every gate in §4 has passed does the correction
/// cascade run.
///
/// ### What it deliberately does not do
/// It never guesses. The cascade in `autocorrectFor` gives up unless exactly
/// one known word is one transposition, one deletion or one insertion away,
/// and replacing a wrong letter with a right one is not in the model at all.
/// Anything it declines is left to the squiggle and the right-click
/// suggestions, which are unchanged.
///
/// A **stored pair** is the one thing here that is not a guess: the user wrote
/// `neve` -> `never` themselves, so it is applied before the cascade is
/// consulted and whether or not autocorrect is switched on
/// (`FLAGGED_WORDS.md` §5).
class AutocorrectSession {
  AutocorrectSession({
    required this.textController,
    required this.resolveEditableState,
    required this.isInsertMode,
    required this.knownWords,
    required this.replacementFor,
    required this.cascadeEnabled,
    required this.isSnippetTrigger,
    required this.snippetExpansionPending,
    required this.snippetIsApplying,
    this.isFieldFocused = _alwaysFocused,
    this.undoController,
  }) {
    _previous = textController.value;
    textController.addListener(_handleEditingChanged);
  }

  final TextEditingController textController;

  /// Resolves the field's [EditableTextState]. Corrections go through
  /// [EditableTextState.userUpdateTextEditingValue] for the same reasons Vim's
  /// and the snippet layer's writes do: input formatters, `onChanged`
  /// (autosave and the journal CRDT depend on seeing every edit), spellcheck
  /// and undo history all hang off that path.
  final EditableTextState? Function() resolveEditableState;

  static bool _alwaysFocused() => true;

  /// Whether the host field still holds the keyboard — see
  /// `SnippetSession.isFieldFocused`.
  final bool Function() isFieldFocused;

  final UndoHistoryController? undoController;

  /// Whether the field is behaving as an insert surface: always true with Vim
  /// off, `VimMode.insert` with no `/` prompt open when Vim is on.
  final bool Function() isInsertMode;

  /// `bundled ∪ custom`, lowercased. Read live rather than captured: the
  /// bundled dictionary loads asynchronously and "Add to dictionary" moves the
  /// set under a field that is already open.
  final Set<String> Function() knownWords;

  /// The replacement stored on a flagged word, or null when the lowercased
  /// token is not flagged or its flag carries none (`FLAGGED_WORDS.md` §5).
  ///
  /// A pair is a rule the user wrote, not a guess, so it is applied before the
  /// cascade is consulted and without its uniqueness search (§5.3).
  final String? Function(String lowerToken) replacementFor;

  /// Whether the *speculative* cascade may run — the user's autocorrect
  /// setting.
  ///
  /// Only the cascade: a stored pair is applied either way
  /// (`FLAGGED_WORDS.md` §5.1). That is why this session is created for every
  /// eligible prose field rather than only while the toggle is on, and why
  /// turning autocorrect off does not forget the pairs.
  final bool Function() cascadeEnabled;

  /// Whether the lowercased token is one of the user's snippet triggers
  /// (AUTOCORRECT.md §4.5).
  final bool Function(String lowerToken) isSnippetTrigger;

  /// Whether the snippet layer has an expansion queued for this keystroke.
  /// Expansion wins the boundary (AUTOCORRECT.md §5.1).
  final bool Function() snippetExpansionPending;

  /// Whether the snippet layer is inside its own write.
  ///
  /// A programmatic expansion must never read as typing (AUTOCORRECT.md §5.2),
  /// and the diff alone cannot always say so: a replacement one character
  /// longer than its trigger and sharing its prefix (`sig` → `sign`) is shaped
  /// exactly like one typed character at the caret. Asked rather than inferred
  /// because [_wasTyped]'s last resort waves every write through on the
  /// platforms with no hardware keyboard.
  final bool Function() snippetIsApplying;

  /// The last correction, for the layer that flashes it. Null between
  /// corrections and after a revert.
  final ValueNotifier<AutocorrectFlash?> flashListenable =
      ValueNotifier<AutocorrectFlash?>(null);

  int _serial = 0;

  /// The value seen at the last notification, for classifying the next one.
  TextEditingValue? _previous;

  /// Set while this session is writing, so a correction never re-enters the
  /// match path and correct itself twice (AUTOCORRECT.md §4.2).
  bool _applying = false;

  bool _disposed = false;

  /// Whether an [EditableTextState] has ever been resolved for this field.
  /// See the fallback in [_applyValue].
  bool _hasEverResolvedState = false;

  /// The character of the last printable key this field saw, consumed by the
  /// next text change. See [_wasTyped].
  String? _typedChar;

  /// The token the user has **typed into** since the caret entered it
  /// (AUTOCORRECT.md §4.3), in current-text offsets — or null when the caret
  /// is not in such a token.
  ///
  /// This is the whole of the "did the user type this word?" rule. Setting it
  /// on every typed word character, mapping it across other edits and dropping
  /// it the moment the caret leaves gives all of §4.3's cases at once: a word
  /// only shortened has never set it, a word typed over a selection cleared it
  /// when the selection was non-collapsed, and a word the caret merely visited
  /// never had it.
  TextRange? _typedToken;

  /// The correction that is still the most recent thing to have happened to
  /// this field, which is what makes Backspace revert it (§7.2) and Ctrl+Z
  /// restore it in one step (§8). Cleared by any other mutation.
  /// [boundaryAt] is the offset of the boundary character the reverting
  /// Backspace deletes, or null when the correction was re-anchored across an
  /// edit the field made for itself — see [revertLastCorrection].
  ({
    TextEditingValue before,
    TextEditingValue after,
    String typo,
    int? boundaryAt,
  })?
  _lastCorrection;

  /// Typos the user has rejected in this field, lowercased (§7.3).
  ///
  /// Keyed on the string rather than on a position, which is what makes the
  /// rejection survive deleting the word and typing it again — including with
  /// Vim's `dw`, which this layer never sees as anything but text changing.
  final Set<String> _suppressed = <String>{};

  /// A correction found but not yet written. Applying it inside the controller
  /// notification that found it would re-enter [EditableTextState] mid-
  /// dispatch, so it is deferred by a microtask — which still lands before the
  /// next frame, so the typo is never painted.
  ({TextEditingValue at, int start, int end, String replacement})? _pending;

  void dispose() {
    _disposed = true;
    textController.removeListener(_handleEditingChanged);
    flashListenable.dispose();
  }

  /// Called by the host when the field loses focus. Autocorrect state belongs
  /// to one editing session, exactly like Vim's mode and the snippet layer's
  /// tabstops — including the suppression set (AUTOCORRECT.md §7.1).
  void reset() {
    _pending = null;
    _lastCorrection = null;
    _typedChar = null;
    _typedToken = null;
    _suppressed.clear();
    if (!_disposed) flashListenable.value = null;
  }

  // ==========================================================================
  // Keys
  // ==========================================================================

  /// Records what the user pressed, whether or not anything claims the key.
  ///
  /// Split out of [handleKey] because the snippet layer gets first refusal on
  /// the keys the two share: a key this session never saw would leave a stale
  /// token behind to vouch for a later programmatic write as typing.
  void noteKey(KeyEvent event) {
    if (_disposed || event is KeyUpEvent) return;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      _typedChar = null;
      return;
    }
    final character = event.character;
    _typedChar = (character != null && character.isNotEmpty) ? character : null;
  }

  /// Claims Backspace for the revert and Ctrl+Z for the undo, and only while
  /// the correction is still the last thing that happened.
  KeyEventResult handleKey(KeyEvent event) {
    if (_disposed || event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;

    if (keyboard.isAltPressed) return KeyEventResult.ignored;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyZ && !keyboard.isShiftPressed) {
        return undoLastCorrection()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.backspace && !keyboard.isShiftPressed) {
      return revertLastCorrection()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  /// Puts the typo back when the user backspaces straight after a correction
  /// (AUTOCORRECT.md §7.2).
  ///
  /// The one keystroke does both halves of "no, I meant that": the boundary
  /// character it would have deleted goes — unless the field wrote past it in
  /// the same keystroke, see below — and the corrected word reverts, in a
  /// single mutation, so one Ctrl+Z brings the correction back. The typo
  /// is flagged by spellcheck again the moment it returns, and joins this
  /// field's suppression set so retyping it does not fight the user a second
  /// time.
  ///
  /// "Straight after" means the correction is still the most recent mutation.
  /// Moving the caret does not cancel it; editing anything does.
  bool revertLastCorrection() {
    final record = _lastCorrection;
    if (record == null) return false;
    if (!_recordStillStands(record.after)) {
      _lastCorrection = null;
      return false;
    }
    final at = record.boundaryAt;
    final text = record.before.text;
    // A null boundary means the correction was re-anchored across an edit the
    // field made for itself — Enter inside a list line, where `onChanged`
    // wrote the continuation marker after the newline. The recorded boundary
    // is then no longer the character this Backspace would have deleted, and
    // deleting it would break the list the field just built, so the keystroke
    // is spent entirely on putting the typo back.
    final restored = at == null
        ? record.before
        : TextEditingValue(
            text: text.substring(0, at) + text.substring(at + 1),
            selection: TextSelection.collapsed(offset: at),
          );
    _applyValue(restored);
    // Committed only once the write has landed, for the reason
    // [_applyCorrection] records: a field whose editable state has gone drops
    // it, and claiming the key anyway would eat a Backspace that did nothing
    // while suppressing the typo for the rest of the session.
    if (textController.value.text != restored.text) return false;
    _lastCorrection = null;
    _typedToken = null;
    _suppressed.add(record.typo.toLowerCase());
    flashListenable.value = null;
    return true;
  }

  /// Whether [after] is still what the field holds, so the correction is
  /// still the most recent thing to have happened to it.
  ///
  /// Text only: [TextEditingValue] equality includes the selection, and
  /// AUTOCORRECT.md §7.2 is explicit that cursor movement alone does not
  /// cancel revert eligibility.
  ///
  /// The mode gate is what that selection comparison was doing by accident.
  /// Vim's `Esc` steps the caret back one character without editing, and it
  /// was only that difference stopping a Normal-mode Backspace — a left
  /// motion, not a delete — or a Normal-mode `Ctrl+Z` from being claimed here
  /// instead of reaching [VimSession]. Autocorrect acts in Insert only
  /// (§4.1), and that now includes the keys it takes back.
  bool _recordStillStands(TextEditingValue after) {
    if (!isInsertMode()) return false;
    return textController.value.text == after.text;
  }

  /// Undoes the correction alone, leaving the boundary character and the
  /// typing before it in place (AUTOCORRECT.md §8).
  ///
  /// Done here rather than left to the field's own undo stack for the reason
  /// `SnippetSession.undoLastExpansion` documents: [UndoHistory] pushes on a
  /// 500ms trailing throttle, so the correction coalesces with the keystrokes
  /// that produced it and Flutter's own Ctrl+Z jumps back past the whole word
  /// instead of restoring the typo.
  bool undoLastCorrection() {
    final record = _lastCorrection;
    if (record == null) return false;
    if (!_recordStillStands(record.after)) {
      _lastCorrection = null;
      return false;
    }
    _lastCorrection = null;
    _typedToken = null;
    // Same UndoHistory assert as Vim's `u` — see [suppressListEditingWrites].
    suppressListEditingWrites(() {
      final undo = undoController;
      if (undo != null && undo.value.canUndo) undo.undo();
      final current = textController.value;
      if (current.text != record.before.text ||
          current.selection != record.before.selection) {
        _applyValue(record.before);
      }
    });
    flashListenable.value = null;
    return true;
  }

  // ==========================================================================
  // Typing
  // ==========================================================================

  void _handleEditingChanged() {
    if (_applying || _disposed) return;
    final value = textController.value;
    final previous = _previous;
    _previous = value;
    if (previous == null) return;

    // One key press accounts for at most one text change, and a key that
    // changed nothing but the selection still spends its token — see the same
    // reasoning in `SnippetSession._handleEditingChanged`.
    final token = _typedChar;
    _typedChar = null;

    if (previous.text == value.text) {
      _dropTypedTokenIfCaretLeft(value.selection);
      return;
    }

    // Any edit at all means the correction is no longer the most recent thing
    // to have happened, so there is nothing left to revert into. This session's
    // own writes never reach here — they run under [_applying].
    _lastCorrection = null;

    final edit = autocorrectEditSpan(
      previous.text,
      value.text,
      value.selection,
    );

    final selection = value.selection;
    final caret = selection.baseOffset;
    final singleInsert =
        edit.removed == 0 &&
        edit.inserted == 1 &&
        selection.isValid &&
        selection.isCollapsed &&
        caret == edit.at + 1 &&
        previous.selection.isValid &&
        previous.selection.isCollapsed;
    final character = singleInsert ? value.text[edit.at] : null;

    final typedToken = _carryTypedToken(
      previous,
      value,
      token,
      edit,
      singleInsert,
    );

    // Where the word would have to end for this keystroke to have finished
    // it. Usually `edit.at`, but the second `_` of a `__` closer finishes the
    // word one offset further back (EMPHASIS_FORMATTING.md §6.2).
    final boundaryTokenEnd = character == null
        ? null
        : autocorrectBoundaryTokenEnd(value.text, edit.at);
    if (boundaryTokenEnd != null &&
        typedToken != null &&
        typedToken.end == boundaryTokenEnd) {
      _considerCorrection(
        previous,
        value,
        token,
        typedToken,
        boundaryAt: edit.at,
      );
    }

    if (character != null &&
        !isAutocorrectBoundary(character) &&
        _wasTyped(previous, value, token)) {
      // A character typed into (or against) a word: that word is now one the
      // user has typed into, whatever it was before. A character that is not
      // part of any word (a digit, a hyphen) falls through and ends the run
      // instead.
      final inside = autocorrectTokenAt(value.text, caret);
      if (inside != null) {
        _typedToken = inside;
        return;
      }
    }

    // The caret leaving a token normally ends the run, with one exception: a
    // `__` or `==` closer is typed one character at a time, and the word it
    // closes has to still be tracked when the pair completes. So the caret is
    // allowed to sit in a run of those characters that starts where the token
    // ends, and nowhere else (EMPHASIS_FORMATTING.md §6.2).
    _typedToken =
        (typedToken != null &&
            (_caretInside(typedToken, selection) ||
                _caretInPendingCloser(value.text, typedToken, selection)))
        ? typedToken
        : null;
  }

  static bool _caretInPendingCloser(
    String text,
    TextRange token,
    TextSelection selection,
  ) {
    if (!selection.isValid || !selection.isCollapsed) return false;
    return isInPendingCloser(text, token.end, selection.baseOffset);
  }

  /// The tracked token as it stands after [edit], or null when the edit
  /// disqualified it.
  ///
  /// An edit that lands *outside* the token simply re-anchors it. An edit that
  /// reaches into it keeps the flag only when it is the user's own work — one
  /// typed character, or a deletion. Anything else rewriting those characters
  /// is a snippet expansion, a paste or a sync pull, and the token it leaves
  /// behind is not one the user typed however much of it they typed before
  /// (AUTOCORRECT.md §5.2).
  TextRange? _carryTypedToken(
    TextEditingValue previous,
    TextEditingValue value,
    String? typedChar,
    ({int at, int removed, int inserted}) edit,
    bool singleInsert,
  ) {
    final token = _typedToken;
    if (token == null) return null;
    // Strict overlap with the replaced span: an insertion at either edge does
    // not reach *into* the token, and re-anchoring handles it.
    final reachesIn =
        edit.at < token.end && edit.at + edit.removed > token.start;
    if (reachesIn) {
      final userEdit =
          (edit.inserted == 0 && edit.removed > 0) ||
          (singleInsert && _wasTyped(previous, value, typedChar));
      if (!userEdit) return null;
    }
    return mapRangeAcrossEdit(token, edit);
  }

  /// Runs every gate in AUTOCORRECT.md §4 and queues the correction if they
  /// all pass.
  void _considerCorrection(
    TextEditingValue previous,
    TextEditingValue value,
    String? typedChar,
    TextRange token, {
    required int boundaryAt,
  }) {
    if (!isInsertMode()) return;
    // The boundary keystroke itself has to be real typing (§4.2): a pasted or
    // synced space must not finish a word.
    if (!_wasTyped(previous, value, typedChar)) return;
    if (!_isSingleInsertAt(previous.text, value.text, boundaryAt)) return;
    // Mid-composition text is not committed yet; the IME's own commit arrives
    // with the range collapsed.
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    // The snippet layer is about to replace this word — its trigger was meant
    // literally (§5.1).
    if (snippetExpansionPending()) return;

    final text = value.text;
    // The tracked span is re-derived from the text rather than trusted: an
    // edit could have joined it to the word beside it since it was recorded.
    final actual = autocorrectTokenAt(text, token.end);
    if (actual == null ||
        actual.start != token.start ||
        actual.end != token.end) {
      return;
    }

    // Only the ASCII half of a word the reader sees as one — `wtih` in
    // `caféwtih`. The squiggle already splits it that way, but underlining a
    // fragment and rewriting one are not the same thing (§4.3).
    if (isAsciiWordFragment(text, token.start, token.end)) return;

    final word = text.substring(token.start, token.end);
    if (isAllCapsToken(word)) return;
    final lower = word.toLowerCase();
    if (_suppressed.contains(lower)) return;
    if (isSnippetTrigger(lower)) return;

    final known = knownWords();
    // Empty until the bundled dictionary has loaded — correcting against a
    // half-built set would "fix" ordinary words, and would let a pair fire
    // against a set that has not yet subtracted the flags
    // (`FLAGGED_WORDS.md` §11).
    if (known.isEmpty) return;

    // A user-written pair skips the cascade entirely: no uniqueness search,
    // no minimum length beyond the tokenizer's, and no autocorrect toggle —
    // they chose this rewrite (`FLAGGED_WORDS.md` §5.1, §5.3 step 3).
    final pair = replacementFor(lower);
    if (pair == null &&
        (!cascadeEnabled() || word.length < kMinAutocorrectLength)) {
      return;
    }

    // A `#tag`, `` `inline code` `` or `$…$` span is not prose (§4.4, and
    // EMPHASIS_FORMATTING.md §6.2 for the third). Parsed rather than sniffed
    // per rule so autocorrect and emphasis can never disagree about where a
    // code span ends — and placed last, since it is the only gate here that
    // scans the whole document.
    if (ProseMarkup.zonesOf(text).any(
      (zone) => token.start < zone.end && token.end > zone.start,
    )) {
      return;
    }
    final correction = pair ?? autocorrectFor(lower, known);
    if (correction == null) return;

    _queueCorrection(
      value,
      token.start,
      token.end,
      applyAutocorrectCase(word, correction),
      boundaryAt: boundaryAt,
    );
  }

  /// Applies a stored replacement to the one occurrence the user pointed at —
  /// the "Replace this one" offer the flag popover makes about the word they
  /// just flagged (`FLAGGED_WORDS.md` §6).
  ///
  /// Routed through the same [_applyCorrection] a boundary rewrite uses rather
  /// than writing the controller directly, which is the whole of §5.4: the
  /// span flashes, one Ctrl+Z brings the flagged spelling back, and an
  /// immediate Backspace reverts it. Nothing else here is offered — the
  /// caller has already decided this span is the flagged word.
  ///
  /// Returns whether the write landed.
  bool applyReplacementAt(TextRange range, String replacement) {
    if (_disposed || replacement.isEmpty) return false;
    final before = textController.value;
    final start = range.start;
    final end = range.end;
    if (start < 0 || end > before.text.length || start >= end) return false;
    final typo = before.text.substring(start, end);
    _applyCorrection(
      before,
      start,
      end,
      applyAutocorrectCase(typo, replacement),
      // No boundary character was typed, so a reverting Backspace has only
      // the word to put back.
      boundaryAt: null,
      // The caret is wherever the right-click left it — usually a selection
      // over the whole word — so it is placed rather than shifted.
      caretAt: start + replacement.length,
    );
    return textController.value.text != before.text;
  }

  void _queueCorrection(
    TextEditingValue at,
    int start,
    int end,
    String replacement, {
    required int boundaryAt,
  }) {
    _pending = (at: at, start: start, end: end, replacement: replacement);
    scheduleMicrotask(() {
      final pending = _pending;
      _pending = null;
      if (_disposed || pending == null) return;
      // The same poll as the one in [_considerCorrection], but this one is
      // order-independent: every controller listener for the notification that
      // found this correction has run by the time a microtask drains, so the
      // snippet layer's queue is authoritative here whichever of the two
      // listeners was registered first. The synchronous gate stays as the
      // cheap early-out for the other order, where the snippet listener ran
      // first and this microtask is the one that drains second
      // (AUTOCORRECT.md §5.1).
      if (snippetExpansionPending()) return;

      final current = textController.value;
      var start = pending.start;
      var end = pending.end;
      // The offset the reverting Backspace deletes — see
      // [revertLastCorrection]. Not always `end`: the second `_` of a `__`
      // closer sits one past it. Only meaningful while that character is
      // still the last thing written.
      int? deletesAt = boundaryAt;
      if (current != pending.at) {
        // The field's own `onChanged` writes again inside this keystroke in
        // every list-aware field: `applyListEditing` appends the continuation
        // marker after an Enter, so by now the value the correction was
        // measured against is not the one on screen. Re-anchored rather than
        // dropped, or §2's newline boundary would silently never fire inside
        // a list line.
        //
        // A change to the selection alone is something else moving the caret
        // mid-keystroke, which is not an edit to re-anchor across.
        if (current.text == pending.at.text) return;
        final moved = mapRangeAcrossEdit(
          TextRange(start: start, end: end),
          autocorrectEditSpan(pending.at.text, current.text, current.selection),
        );
        if (moved == null) return;
        start = moved.start;
        end = moved.end;
        // Only proceed if the span still reads as exactly the typo that was
        // matched; anything else and the intervening write was not the benign
        // one this branch is for.
        if (start < 0 || end > current.text.length || start >= end) return;
        if (current.text.substring(start, end) !=
            pending.at.text.substring(pending.start, pending.end)) {
          return;
        }
        deletesAt = null;
      }
      _applyCorrection(
        current,
        start,
        end,
        pending.replacement,
        boundaryAt: deletesAt,
      );
    });
  }

  void _applyCorrection(
    TextEditingValue before,
    int start,
    int end,
    String replacement, {
    required int? boundaryAt,
    int? caretAt,
  }) {
    final typo = before.text.substring(start, end);
    final delta = replacement.length - typo.length;
    final after = TextEditingValue(
      text: before.text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(
        offset: caretAt ?? before.selection.baseOffset + delta,
      ),
    );
    _applyValue(after);
    // Only remembered if the write actually landed: a field that has lost
    // focus drops it, and there would be nothing to revert.
    if (textController.value != after) return;
    _lastCorrection = (
      before: before,
      after: after,
      typo: typo,
      boundaryAt: boundaryAt,
    );
    _typedToken = null;
    flashListenable.value = AutocorrectFlash(
      range: TextRange(start: start, end: start + replacement.length),
      serial: ++_serial,
    );
  }

  void _applyValue(TextEditingValue value) {
    _applying = true;
    try {
      final state = resolveEditableState();
      if (state != null) {
        _hasEverResolvedState = true;
        state.userUpdateTextEditingValue(value, SelectionChangedCause.keyboard);
      } else if (isFieldFocused() && !_hasEverResolvedState) {
        // Before the field's first frame, where there is no state to resolve
        // yet. Once one *has* been resolved, a null answer means the host
        // swapped the field out from under a still-focused scope, and a write
        // straight to the controller there would skip the input formatters,
        // `onChanged` (autosave and the journal CRDT) and undo history — so
        // the correction is dropped instead of landing somewhere nothing can
        // see it.
        textController.value = value;
      }
      // Otherwise focus has moved on and the write is stale: dropped rather
      // than sent to whichever field holds the keyboard now.
    } finally {
      _applying = false;
      _previous = textController.value;
    }
  }

  void _dropTypedTokenIfCaretLeft(TextSelection selection) {
    final token = _typedToken;
    if (token == null) return;
    if (!_caretInside(token, selection)) _typedToken = null;
  }

  static bool _caretInside(TextRange range, TextSelection selection) {
    if (!selection.isValid || !selection.isCollapsed) return false;
    final caret = selection.baseOffset;
    return caret >= range.start && caret <= range.end;
  }

  /// Whether the single character this change added was actually *typed* —
  /// the same discriminator, and the same two exceptions (an IME commit, a
  /// soft keyboard), as `SnippetSession._wasTyped`.
  bool _wasTyped(
    TextEditingValue previous,
    TextEditingValue value,
    String? typed,
  ) {
    // Never, whatever the diff looks like: the snippet layer is mid-write, and
    // an expansion one character longer than its trigger is indistinguishable
    // from a typed character by shape alone (AUTOCORRECT.md §5.2). Checked
    // first because the fallback below waves every write through on the
    // platforms with no hardware keyboard, where that is the only thing
    // standing between an expansion and being autocorrected.
    if (snippetIsApplying()) return false;
    final caret = value.selection.baseOffset;
    if (caret <= 0 || caret > value.text.length) return false;
    if (typed != null &&
        typed.length == 1 &&
        typed.codeUnitAt(0) == value.text.codeUnitAt(caret - 1)) {
      return true;
    }
    if (previous.composing.isValid && !previous.composing.isCollapsed) {
      return true;
    }
    return !_hardwareKeyboardTypes;
  }

  static bool get _hardwareKeyboardTypes => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  /// Whether [next] is [old] with exactly one character inserted at [at].
  /// Compares in place, so a long journal body costs a scan and no allocation.
  static bool _isSingleInsertAt(String old, String next, int at) {
    if (next.length != old.length + 1 || at < 0 || at > old.length) {
      return false;
    }
    for (var i = 0; i < at; i++) {
      if (old.codeUnitAt(i) != next.codeUnitAt(i)) return false;
    }
    for (var i = at; i < old.length; i++) {
      if (old.codeUnitAt(i) != next.codeUnitAt(i + 1)) return false;
    }
    return true;
  }
}

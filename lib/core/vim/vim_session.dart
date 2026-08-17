import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/vim/vim_text_ops.dart';

/// The editing modes Voyager's Vim layer implements.
///
/// Fields always start in [insert] (see `VIM.md` and the decision recorded in
/// `vim_text_scope.dart`): clicking into any box types normally, and `Esc`
/// opts into [normal].
enum VimMode { insert, normal, visual, visualLine }

extension VimModeX on VimMode {
  bool get isVisual => this == VimMode.visual || this == VimMode.visualLine;

  /// Label shown in the mode badge. Insert deliberately has none — the badge
  /// is hidden entirely in Insert so an unaware user never sees Vim chrome.
  String get label => switch (this) {
    VimMode.insert => 'INSERT',
    VimMode.normal => 'NORMAL',
    VimMode.visual => 'VISUAL',
    VimMode.visualLine => 'V-LINE',
  };
}

/// Vim's unnamed register, shared by every field in the app as it is shared by
/// every buffer in Vim.
///
/// Deliberately *not* mirrored to the OS clipboard. Stock Vim only does that
/// under `clipboard=unnamedplus`, and with no numbered registers to fall back
/// on here every `x` and `dd` would silently destroy whatever you had copied —
/// and, on Windows, leave a copy of it in the Win+V clipboard history. Both
/// directions stay reachable explicitly instead: `<C-v>` pastes the clipboard
/// in, and `<C-c>` over a Visual selection falls through to Flutter's own copy
/// (Visual mode drives the field's real [TextSelection], see
/// `_visualSelection`).
///
/// [linewise] is what makes `dd` then `p` put a whole line *below* the caret
/// instead of splicing it mid-line.
class VimRegister {
  VimRegister._();

  static String text = '';
  static bool linewise = false;

  static void write(String value, {required bool asLines}) {
    text = value;
    linewise = asLines;
  }
}

/// The last `/` pattern and direction, shared across fields so `n` keeps
/// working after you tab to another box — matching Vim's global search
/// register.
class VimSearchMemory {
  VimSearchMemory._();

  static String pattern = '';
  static bool forward = true;
}

/// Live state of the `/` prompt, rendered by the search bar under the field.
@immutable
class VimSearchPrompt {
  const VimSearchPrompt({
    required this.query,
    required this.forward,
    required this.matchCount,
    required this.matchIndex,
  });

  final String query;
  final bool forward;
  final int matchCount;

  /// 1-based position of the previewed match, or 0 when there is none.
  final int matchIndex;

  @override
  bool operator ==(Object other) =>
      other is VimSearchPrompt &&
      other.query == query &&
      other.forward == forward &&
      other.matchCount == matchCount &&
      other.matchIndex == matchIndex;

  @override
  int get hashCode => Object.hash(query, forward, matchCount, matchIndex);
}

/// What the state machine is waiting for after a prefix key.
enum _Await { none, findChar, replaceChar, gPrefix, textObject }

/// A replayable record of the last mutating command, backing `.`.
///
/// [keys] is the literal key sequence that produced it — counts included, so
/// `.` after `2dw` deletes two words again — and [insertedText] carries the
/// characters typed before `Esc` for commands that ended in Insert mode.
class _DotRecord {
  _DotRecord(this.keys, this.insertedText);

  final List<String> keys;
  final String? insertedText;
}

/// The Vim state machine for a single text field.
///
/// One session is created per focused field by `VimTextScope`. It owns the
/// mode, the pending-command state, and every mutation of the field's text.
///
/// ### Performance shape
/// All state lives in three [ValueNotifier]s with deliberately different
/// change rates, so a keystroke only rebuilds what actually changed:
/// [modeListenable] fires on mode transitions (rare, and the only one the
/// host field listens to, since only it changes the caret shape),
/// [hudListenable] fires on pending-key changes (cheap — a 20-glyph badge),
/// and [searchListenable] fires only while the `/` bar is open. Nothing here
/// calls `setState` on the field itself.
class VimSession {
  VimSession({
    required this.textController,
    required this.resolveEditableState,
    required this.isMultiline,
    this.trySnippetUndo,
  });

  final TextEditingController textController;

  /// Resolves the field's [EditableTextState]. Every text mutation goes
  /// through [EditableTextState.userUpdateTextEditingValue] rather than
  /// `controller.value =`, because only that path runs input formatters,
  /// fires `onChanged` (autosave/sync depend on it), refreshes spellcheck,
  /// and records an undo entry — see the `project_flutter_spellcheck_freeze`
  /// notes on bug 6. The direct-write fallback exists only for the window
  /// before the field's first frame, where there is no state to resolve.
  final EditableTextState? Function() resolveEditableState;

  /// Whether the host field can hold more than one line. Single-line fields
  /// reinterpret `o`/`O` as plain Insert-mode entry instead of splitting the
  /// value with a newline the field could never render.
  final bool Function() isMultiline;

  /// Tries to revert the last snippet expansion as one undo atom.
  ///
  /// Wired live by `VimTextScope` so Normal `u` can share `SnippetSession`'s
  /// undo path without holding a session that settings sync may recreate.
  /// Null in tests that do not care, and a no-op when snippets are off.
  final bool Function()? trySnippetUndo;

  /// Undo stack for the host field, driven by `u` and `<C-r>`.
  ///
  /// Owned here (rather than left to the field's own internal one) purely so
  /// those two keys have something to call: `UndoHistoryController.undo` is
  /// the only public entry point, and it needs the same controller instance
  /// the field was built with.
  final UndoHistoryController undoController = UndoHistoryController();

  final ValueNotifier<VimMode> modeListenable = ValueNotifier<VimMode>(
    VimMode.insert,
  );

  /// The pending command as typed, e.g. `"2d"` or `"ci"`, shown next to the
  /// mode badge so a half-finished operator is visible rather than silent.
  final ValueNotifier<String> hudListenable = ValueNotifier<String>('');

  final ValueNotifier<VimSearchPrompt?> searchListenable =
      ValueNotifier<VimSearchPrompt?>(null);

  /// The pattern every occurrence of which is currently highlighted in the
  /// field, or `''` for none. Vim's `hlsearch`: set while the `/` prompt is
  /// being typed and kept after it is accepted, so the other matches stay
  /// marked while `n`/`N` walk between them, and cleared by `Esc` in Normal
  /// mode (`:nohlsearch`).
  ///
  /// Rendered by `VimTextOverlay`, which paints the occurrences in a colour of
  /// their own so they read as "the other hits" next to the caret's own.
  final ValueNotifier<String> searchHighlightListenable = ValueNotifier<String>(
    '',
  );

  VimMode get mode => modeListenable.value;

  /// The character the block caret sits on: the collapsed caret in Normal
  /// mode, the moving end of the selection in Visual.
  int get caretOffset => _cursor;

  /// [caretOffset], republished on every move.
  ///
  /// The overlay used to read the caret at paint time and rely on the
  /// controller to tell it when to repaint, on the grounds that every caret
  /// move goes through [_applyValue]. That holds everywhere except linewise
  /// Visual: `V` snaps its selection to whole lines, so a caret-only change
  /// (for example pinning to end-of-line after `j`) can hand the controller a
  /// value identical to the one it already has. This notifier is the signal
  /// that doesn't go through the selection.
  final ValueNotifier<int> caretListenable = ValueNotifier<int>(0);

  /// Sticky column used in linewise Visual so `j`/`k`/`G`/`{`/`}` always land
  /// on the last character of the destination line.
  static const int _visualLineEndColumn = 1 << 30;

  /// Offsets of every occurrence of [searchHighlightListenable]'s pattern, for
  /// the overlay to paint. Empty when nothing is highlighted.
  List<int> get searchHighlightOffsets {
    final pattern = searchHighlightListenable.value;
    if (pattern.isEmpty) return const [];
    return _matchesFor(pattern);
  }

  /// Length of one highlighted occurrence.
  int get searchHighlightLength => searchHighlightListenable.value.length;

  // --- pending command state ------------------------------------------------
  int _count = 0;
  String? _operator;
  int _operatorCount = 0;
  _Await _await = _Await.none;
  VimCharSearch? _pendingSearchTemplate;
  bool _textObjectInner = true;

  // --- visual state ---------------------------------------------------------
  int _visualAnchor = 0;
  int _visualCursor = 0;

  /// Sticky column for `j`/`k`, so moving through a ragged paragraph doesn't
  /// creep left one short line at a time.
  int _desiredColumn = 0;

  // --- repeat / dot state ---------------------------------------------------
  final List<String> _commandKeys = <String>[];
  _DotRecord? _lastAction;
  bool _replaying = false;

  /// Where the current Insert session began, and the command that opened it —
  /// together they let `.` replay "change this word and type *that*".
  int? _insertAnchor;
  List<String>? _insertCommandKeys;

  // --- search state ---------------------------------------------------------
  String _searchQuery = '';
  bool _searchForward = true;
  int _searchOriginOffset = 0;
  List<int>? _cachedMatches;
  String? _cachedMatchesFor;
  String? _cachedMatchesPattern;

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    modeListenable.dispose();
    hudListenable.dispose();
    searchListenable.dispose();
    searchHighlightListenable.dispose();
    caretListenable.dispose();
    undoController.dispose();
  }

  // ==========================================================================
  // Value access
  // ==========================================================================

  String get _text => textController.text;

  /// The caret as a character index. In Normal mode that is the collapsed
  /// selection; in Visual it is the moving end, tracked separately because the
  /// displayed selection extends one past it to cover the character the caret
  /// sits *on*.
  int get _cursor {
    if (mode.isVisual) return _visualCursor.clamp(0, _text.length);
    final selection = textController.selection;
    if (!selection.isValid) return 0;
    return selection.baseOffset.clamp(0, _text.length);
  }

  void _applyValue(TextEditingValue value) {
    final state = resolveEditableState();
    if (state != null) {
      state.userUpdateTextEditingValue(value, SelectionChangedCause.keyboard);
    } else {
      textController.value = value;
    }
    // No explicit "scroll the caret into view" step is needed:
    // userUpdateTextEditingValue schedules its own whenever the selection
    // moves, and the fallback branch above only runs before the field's first
    // frame, when there is nothing to scroll yet.
    if (!_disposed) caretListenable.value = caretOffset;
  }

  /// Moves the caret without touching the text, rendering the selection the
  /// current mode implies.
  void _setCursor(int offset, {bool allowLineEnd = false}) {
    final text = _text;
    if (mode == VimMode.visualLine) {
      // Linewise Visual keeps the block caret on the last character of the
      // line it sits on — never past it, and never mid-line after a motion.
      _visualCursor = vimClampCaret(text, vimLineEnd(text, offset));
      _applyValue(textController.value.copyWith(selection: _visualSelection()));
      return;
    }
    if (mode == VimMode.visual) {
      // Charwise Visual may sit on a character, never past the last one on a
      // line (that would paint a highlight over text that does not exist).
      _visualCursor = vimClampCaret(text, offset);
      _applyValue(textController.value.copyWith(selection: _visualSelection()));
      return;
    }
    final clamped = vimClampCaret(text, offset, allowLineEnd: allowLineEnd);
    _applyValue(
      textController.value.copyWith(
        selection: TextSelection.collapsed(offset: clamped),
        composing: TextRange.empty,
      ),
    );
  }

  /// Last character of the line containing [offset] (line start when empty).
  int _lineLastChar(int offset) =>
      vimClampCaret(_text, vimLineEnd(_text, offset));

  /// Charwise Visual `l` / → / Space: step right, wrapping onto the next line
  /// instead of landing past the last character.
  int _visualCharRight(int count) {
    final text = _text;
    var o = _cursor;
    for (var i = 0; i < count; i++) {
      final end = vimLineEnd(text, o);
      final start = vimLineStart(text, o);
      if (end > start && o < end - 1) {
        o++;
      } else if (end < text.length) {
        o = end + 1;
      } else {
        break;
      }
    }
    return o;
  }

  /// Horizontal motions are meaningless in linewise Visual — the caret is
  /// locked to end-of-line. Swallow the key and clear any pending count.
  bool _blockVisualLineHorizontal() {
    if (mode != VimMode.visualLine) return false;
    _clearPending();
    return true;
  }

  /// Selection to display for the current visual mode: charwise selections
  /// include the character under the caret; linewise ones snap to whole lines.
  TextSelection _visualSelection() {
    final text = _text;
    if (mode == VimMode.visualLine) {
      final lo = math.min(_visualAnchor, _visualCursor);
      final hi = math.max(_visualAnchor, _visualCursor);
      return TextSelection(
        baseOffset: vimLineStart(text, lo),
        extentOffset: vimLineEnd(text, hi),
      );
    }
    if (_visualCursor >= _visualAnchor) {
      return TextSelection(
        baseOffset: _visualAnchor,
        extentOffset: math.min(text.length, _visualCursor + 1),
      );
    }
    return TextSelection(
      baseOffset: math.min(text.length, _visualAnchor + 1),
      extentOffset: _visualCursor,
    );
  }

  /// The `[start, end)` span the current visual selection covers, as an
  /// operator would read it.
  VimRange _visualRange() {
    final text = _text;
    if (mode == VimMode.visualLine) {
      return vimLinewiseRange(text, _visualAnchor, _visualCursor);
    }
    final lo = math.min(_visualAnchor, _visualCursor);
    final hi = math.max(_visualAnchor, _visualCursor);
    return VimRange(lo, math.min(text.length, hi + 1));
  }

  // ==========================================================================
  // Mode transitions
  // ==========================================================================

  void _setMode(VimMode next) {
    if (modeListenable.value == next) return;
    modeListenable.value = next;
  }

  /// Called by the host when the field loses focus: Vim state is per editing
  /// session, so the next focus starts clean in Insert.
  void reset() {
    if (_disposed) return;
    _clearPending();
    _cancelSearchPrompt(restoreCaret: false);
    searchHighlightListenable.value = '';
    _insertAnchor = null;
    _insertCommandKeys = null;
    final wasVisual = mode.isVisual;
    _setMode(VimMode.insert);
    // A Visual range must not outlive the mode that drew it. The overlay is
    // what paints a `V` selection accurately, and it only does so in Visual
    // mode — leave the range in the controller and the field falls back to
    // Flutter's own highlight, which pads every covered line out to the width
    // of the widest one. That is what turned a highlight into a solid block
    // after alt-tabbing away and back: losing focus drops to Insert, and the
    // selection was staying behind.
    if (wasVisual) {
      _applyValue(
        textController.value.copyWith(
          selection: TextSelection.collapsed(
            offset: _visualCursor.clamp(0, _text.length),
          ),
          composing: TextRange.empty,
        ),
      );
    }
  }

  /// Undoes the select-all a field does when focus comes back to it after a
  /// window switch, putting [selection] — what Vim had before the switch —
  /// back.
  ///
  /// The mode survives that switch (see `VimTextScope`), but the selection
  /// underneath it does not: desktop [EditableText] selects the whole of a
  /// single-line field whenever it takes focus, and the framework hands the
  /// focus back by itself when the window returns. Normal mode would come back
  /// with its caret at the end of the field, and Visual mode with its range
  /// painted over everything.
  ///
  /// Narrowed to exactly that case — the field is now selected end to end and
  /// was not before — because the way *back* into a field can also be a click
  /// in it, and a caret the user placed themselves must stay where they put
  /// it. Same rule, for the same reason, as
  /// `PreserveSelectionOnAppResume.restoreIfSelectAll`.
  void restoreSelection(TextSelection selection) {
    if (_disposed || !selection.isValid) return;
    final max = _text.length;
    if (max == 0) return;
    final current = textController.selection;
    if (!current.isValid || current.isCollapsed) return;
    if (current.start != 0 || current.end != max) return;
    if (selection.start == 0 && selection.end == max) return;
    final restored = TextSelection(
      baseOffset: selection.baseOffset.clamp(0, max),
      extentOffset: selection.extentOffset.clamp(0, max),
      affinity: selection.affinity,
    );
    if (textController.selection == restored) return;
    _applyValue(
      textController.value.copyWith(
        selection: restored,
        composing: TextRange.empty,
      ),
    );
  }

  /// `Esc` from Insert: commit the dot-record (command + the text just typed)
  /// and step the caret back onto the last typed character, as Vim does.
  void _leaveInsert() {
    final anchor = _insertAnchor;
    final commandKeys = _insertCommandKeys;
    if (commandKeys != null && anchor != null) {
      final caret = textController.selection.isValid
          ? textController.selection.baseOffset
          : anchor;
      // Only record a *simple forward insert*. Anything else (the user
      // arrowed around, deleted back past the anchor, pasted) can't be
      // replayed faithfully by re-typing a substring, so the record keeps
      // the command alone rather than replaying wrong text.
      final inserted = caret > anchor && caret <= _text.length
          ? _text.substring(anchor, caret)
          : null;
      _lastAction = _DotRecord(
        List<String>.unmodifiable(commandKeys),
        inserted,
      );
    }
    _insertAnchor = null;
    _insertCommandKeys = null;
    _setMode(VimMode.normal);
    _clearPending();
    final caret = textController.selection.isValid
        ? textController.selection.baseOffset
        : 0;
    _setCursor(_caretAfterInsert(caret));
  }

  /// Where the caret lands when Insert mode ends.
  ///
  /// Vim steps back onto the character just typed — but only within the line.
  /// Stepping back unconditionally is what sent the caret up a row whenever
  /// Insert was left from the first column: the character before a line's
  /// start is the previous line's newline, and on an empty line there is
  /// nothing on this line to step onto at all.
  int _caretAfterInsert(int caret) {
    final clamped = caret.clamp(0, _text.length);
    return clamped > vimLineStart(_text, clamped) ? clamped - 1 : clamped;
  }

  void _enterVisual(VimMode which) {
    var caret = vimClampCaret(_text, _cursor);
    if (which == VimMode.visualLine) {
      caret = _lineLastChar(caret);
      _desiredColumn = _visualLineEndColumn;
    }
    _visualAnchor = caret;
    _visualCursor = caret;
    _setMode(which);
    _applyValue(textController.value.copyWith(selection: _visualSelection()));
    _clearPending();
  }

  /// Switch an existing charwise Visual selection into linewise, pinning the
  /// moving end to end-of-line so the caret matches `V` entered from Normal.
  void _promoteToVisualLine() {
    _setMode(VimMode.visualLine);
    _visualCursor = _lineLastChar(_visualCursor);
    _desiredColumn = _visualLineEndColumn;
    _applyValue(textController.value.copyWith(selection: _visualSelection()));
    _clearPending();
  }

  void _leaveVisual({int? caret}) {
    final target = caret ?? _visualCursor;
    _setMode(VimMode.normal);
    _clearPending();
    _setCursor(target);
  }

  void _clearPending() {
    _count = 0;
    _operator = null;
    _operatorCount = 0;
    _await = _Await.none;
    _pendingSearchTemplate = null;
    if (!_replaying) _commandKeys.clear();
    _publishHud();
  }

  void _publishHud() {
    if (_disposed) return;
    final buffer = StringBuffer();
    if (_count > 0) buffer.write(_count);
    if (_operator != null) {
      if (_operatorCount > 0) buffer.write(_operatorCount);
      buffer.write(_operator);
    }
    switch (_await) {
      case _Await.findChar:
        final template = _pendingSearchTemplate;
        final letter = (template?.till ?? false) ? 't' : 'f';
        buffer.write(
          (template?.forward ?? true) ? letter : letter.toUpperCase(),
        );
      case _Await.replaceChar:
        buffer.write('r');
      case _Await.gPrefix:
        buffer.write('g');
      case _Await.textObject:
        buffer.write(_textObjectInner ? 'i' : 'a');
      case _Await.none:
        break;
    }
    hudListenable.value = buffer.toString();
  }

  // ==========================================================================
  // Key entry point
  // ==========================================================================

  /// Handles one key event for the focused field.
  ///
  /// Returns [KeyEventResult.handled] for anything Vim consumes. On desktop
  /// that is what stops the character reaching the text input plugin, so
  /// Normal mode consumes *every* printable key rather than allowlisting the
  /// ones it understands — an unmapped letter must not type itself.
  KeyEventResult handleKey(KeyEvent event) {
    if (_disposed) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (_isModifierKey(key)) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    final meta = keyboard.isMetaPressed;

    if (searchListenable.value != null) {
      return _handleSearchKey(event, key, ctrl: ctrl, alt: alt, meta: meta);
    }

    if (mode == VimMode.insert) {
      if (key == LogicalKeyboardKey.escape ||
          (ctrl && key == LogicalKeyboardKey.bracketLeft)) {
        _leaveInsert();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Alt/Meta chords belong to the OS and the app's own shortcuts.
    if (alt || meta) return KeyEventResult.ignored;
    if (ctrl) return _handleControlKey(key);

    if (key == LogicalKeyboardKey.escape) {
      if (mode.isVisual) {
        _leaveVisual();
        return KeyEventResult.handled;
      }
      if (_hasPendingState) {
        _clearPending();
        return KeyEventResult.handled;
      }
      // Vim's `:nohlsearch`: the search highlights outlive the `/` prompt so
      // they stay marked while `n`/`N` walk between them, and Escape is what
      // puts them away.
      if (searchHighlightListenable.value.isNotEmpty) {
        searchHighlightListenable.value = '';
        return KeyEventResult.handled;
      }
      // Nothing left to cancel, and Escape *still* stops here. Reaching for
      // Normal mode is a reflex — the key gets tapped twice, or held — and
      // every press past the first used to bubble out and dismiss the dialog
      // the field was sitting in, losing whatever had been typed. A focused
      // Vim field owns Escape outright; the dialog is closed by its buttons,
      // by clicking away, or after tabbing out of the box.
      return KeyEventResult.handled;
    }

    // Focus traversal stays available in every mode.
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;

    final navigated = _handleNavigationKey(key);
    if (navigated != null) return navigated;

    final character = event.character;
    if (character == null || character.isEmpty) {
      // A non-printing key with no Vim meaning (F-keys, media keys): let it
      // through so app-level shortcuts keep working.
      return KeyEventResult.ignored;
    }
    _handleChar(character);
    return KeyEventResult.handled;
  }

  bool get _hasPendingState =>
      _count > 0 || _operator != null || _await != _Await.none;

  static bool _isModifierKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.shift ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.control ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.alt ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.meta ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.capsLock;

  KeyEventResult _handleControlKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.bracketLeft) {
      if (mode.isVisual) {
        _leaveVisual();
      } else {
        _clearPending();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      if (undoController.value.canRedo) {
        // Same UndoHistory assert as `u` — see [suppressListEditingWrites].
        suppressListEditingWrites(undoController.redo);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC && mode.isVisual) {
      // The copy itself is Flutter's — this returns `ignored` so the press
      // carries on to `DefaultTextEditingShortcuts`, which reads the very
      // selection Visual mode put in the controller. Dropping out of Visual
      // *afterwards* is what makes the copy feel like it landed: the text is
      // on the clipboard, so the highlight has done its job and holding onto
      // it just leaves the user to press Escape for no reason. Deferred to a
      // microtask because collapsing the selection here — inside the same key
      // dispatch — would take it away before the copy handler ever saw it.
      scheduleMicrotask(() {
        if (_disposed || !mode.isVisual) return;
        _leaveVisual();
      });
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyV) {
      _pasteFromSystemClipboard();
      return KeyEventResult.handled;
    }
    // Half-page scrolls. Fields here are short enough that a fixed jump reads
    // better than measuring the viewport every press.
    if (key == LogicalKeyboardKey.keyD) {
      _moveVertically(_halfPageLines);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyU) {
      _moveVertically(-_halfPageLines);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static const int _halfPageLines = 10;

  /// Arrow/Home/End/PageUp/PageDown behave like their Vim equivalents so the
  /// field stays usable without the letter keys.
  KeyEventResult? _handleNavigationKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_blockVisualLineHorizontal()) return KeyEventResult.handled;
      _applyMotion(VimMotion.exclusive(_cursor - _takeCount()));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_blockVisualLineHorizontal()) return KeyEventResult.handled;
      if (mode == VimMode.visual) {
        _applyMotion(VimMotion.exclusive(_visualCharRight(_takeCount())));
      } else {
        _applyMotion(VimMotion.exclusive(_cursor + _takeCount()));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveVertically(_takeCount());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveVertically(-_takeCount());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      if (_blockVisualLineHorizontal()) return KeyEventResult.handled;
      _applyMotion(VimMotion.exclusive(vimLineStart(_text, _cursor)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (_blockVisualLineHorizontal()) return KeyEventResult.handled;
      _applyMotion(VimMotion.inclusive(vimLineEnd(_text, _cursor) - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _moveVertically(_halfPageLines * 2);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _moveVertically(-_halfPageLines * 2);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (_blockVisualLineHorizontal()) return KeyEventResult.handled;
      _applyMotion(VimMotion.exclusive(_cursor - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      _deleteCharsForward(_takeCount());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final target = vimVerticalMove(
        _text,
        _cursor,
        _takeCount(),
        desiredColumn: 0,
      );
      _applyMotion(VimMotion.linewise(vimFirstNonBlank(_text, target)));
      return KeyEventResult.handled;
    }
    return null;
  }

  // ==========================================================================
  // Normal / Visual character dispatch
  // ==========================================================================

  void _handleChar(String ch) {
    if (!_replaying) _commandKeys.add(ch);

    switch (_await) {
      case _Await.findChar:
        _completeCharSearch(ch);
        return;
      case _Await.replaceChar:
        _completeReplaceChar(ch);
        return;
      case _Await.gPrefix:
        _completeGPrefix(ch);
        return;
      case _Await.textObject:
        _completeTextObject(ch);
        return;
      case _Await.none:
        break;
    }

    // Counts. A leading `0` is the line-start motion, not a count digit.
    if (ch.length == 1) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39 && !(code == 0x30 && _count == 0)) {
        _count = _count * 10 + (code - 0x30);
        _publishHud();
        return;
      }
    }

    // `o` swaps the moving end of a Visual selection; it only means "open a
    // line" in Normal mode, so it has to be peeled off before the table below.
    if (mode.isVisual && ch == 'o') {
      final anchor = _visualAnchor;
      _visualAnchor = _visualCursor;
      _visualCursor = anchor;
      if (mode == VimMode.visualLine) {
        _visualAnchor = _lineLastChar(_visualAnchor);
        _visualCursor = _lineLastChar(_visualCursor);
      }
      _applyValue(textController.value.copyWith(selection: _visualSelection()));
      _clearPending();
      return;
    }

    // `i`/`a` introduce a text object whenever something is waiting for a
    // range — a pending operator (`ciw`) or a live Visual selection (`vi(`).
    // Only in plain Normal mode do they enter Insert.
    final expectsRange = _operator != null || mode.isVisual;
    if (expectsRange && (ch == 'i' || ch == 'a')) {
      if (mode == VimMode.visualLine) {
        _clearPending();
        return;
      }
      _textObjectInner = ch == 'i';
      _await = _Await.textObject;
      _publishHud();
      return;
    }

    switch (ch) {
      // ---- mode switches ----
      case 'i':
        _startInsertCommand(_cursor, keys: const ['i']);
      case 'a':
        _startInsertCommand(
          vimAppendOffset(_text, _cursor),
          keys: const ['a'],
          affinity: TextAffinity.upstream,
        );
      case 'I':
        _startInsertCommand(
          vimFirstNonBlank(_text, _cursor),
          keys: const ['I'],
        );
      case 'A':
        _startInsertCommand(
          vimLineEnd(_text, _cursor),
          keys: const ['A'],
          affinity: TextAffinity.upstream,
        );
      case 'o':
        _openLine(below: true);
      case 'O':
        _openLine(below: false);
      case 'v':
        if (mode == VimMode.visual) {
          _leaveVisual();
        } else if (mode == VimMode.visualLine) {
          _setMode(VimMode.visual);
          _applyValue(
            textController.value.copyWith(selection: _visualSelection()),
          );
          _clearPending();
        } else {
          _enterVisual(VimMode.visual);
        }
      case 'V':
        if (mode == VimMode.visualLine) {
          _leaveVisual();
        } else if (mode == VimMode.visual) {
          _promoteToVisualLine();
        } else {
          _enterVisual(VimMode.visualLine);
        }

      // ---- motions ----
      case 'h':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(VimMotion.exclusive(_cursor - _takeCount()));
      case 'l':
        if (_blockVisualLineHorizontal()) return;
        if (mode == VimMode.visual) {
          _applyMotion(VimMotion.exclusive(_visualCharRight(_takeCount())));
        } else {
          _applyMotion(VimMotion.exclusive(_cursor + _takeCount()));
        }
      case ' ':
        if (_blockVisualLineHorizontal()) return;
        if (mode == VimMode.visual) {
          _applyMotion(VimMotion.exclusive(_visualCharRight(_takeCount())));
        } else {
          _applyMotion(VimMotion.exclusive(_cursor + _takeCount()));
        }
      case 'j':
        _moveVertically(_takeCount());
      case 'k':
        _moveVertically(-_takeCount());
      case 'w':
      case 'W':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(
          VimMotion.exclusive(
            _repeat(
              _cursor,
              _takeCount(),
              (o) => vimWordForward(_text, o, big: ch == 'W'),
            ),
          ),
        );
      case 'b':
      case 'B':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(
          VimMotion.exclusive(
            _repeat(
              _cursor,
              _takeCount(),
              (o) => vimWordBackward(_text, o, big: ch == 'B'),
            ),
          ),
        );
      case 'e':
      case 'E':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(
          VimMotion.inclusive(
            _repeat(
              _cursor,
              _takeCount(),
              (o) => vimWordEnd(_text, o, big: ch == 'E'),
            ),
          ),
        );
      case '0':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(VimMotion.exclusive(vimLineStart(_text, _cursor)));
      case '^':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(VimMotion.exclusive(vimFirstNonBlank(_text, _cursor)));
      case r'$':
        if (_blockVisualLineHorizontal()) return;
        final count = _takeCount();
        final target = count > 1
            ? vimVerticalMove(_text, _cursor, count - 1, desiredColumn: 1 << 30)
            : _cursor;
        _applyMotion(
          VimMotion.inclusive(math.max(0, vimLineEnd(_text, target) - 1)),
        );
      case '{':
        _applyMotion(
          VimMotion.exclusive(
            _repeat(
              _cursor,
              _takeCount(),
              (o) => vimParagraphBackward(_text, o),
            ),
          ),
        );
      case '}':
        _applyMotion(
          VimMotion.exclusive(
            _repeat(
              _cursor,
              _takeCount(),
              (o) => vimParagraphForward(_text, o),
            ),
          ),
        );
      case '%':
        if (_blockVisualLineHorizontal()) return;
        final target = vimMatchBracket(_text, _cursor);
        if (target != null) {
          _applyMotion(VimMotion.inclusive(target));
        } else {
          _clearPending();
        }
      case '|':
        if (_blockVisualLineHorizontal()) return;
        final column = math.max(0, _takeCount() - 1);
        _applyMotion(
          VimMotion.exclusive(vimLineStart(_text, _cursor) + column),
        );
      case 'G':
        final count = _consumeCount();
        final target = count != null
            ? vimOffsetOfLine(_text, count - 1)
            : vimLineStart(_text, _text.length);
        _applyMotion(VimMotion.linewise(vimFirstNonBlank(_text, target)));
      case 'g':
        _await = _Await.gPrefix;
        _publishHud();
        return;
      case '+':
        _applyMotion(
          VimMotion.linewise(
            vimFirstNonBlank(
              _text,
              vimVerticalMove(_text, _cursor, _takeCount(), desiredColumn: 0),
            ),
          ),
        );
      case '-':
        _applyMotion(
          VimMotion.linewise(
            vimFirstNonBlank(
              _text,
              vimVerticalMove(_text, _cursor, -_takeCount(), desiredColumn: 0),
            ),
          ),
        );

      // ---- transient (find) motions ----
      case 'f':
      case 'F':
      case 't':
      case 'T':
        if (_blockVisualLineHorizontal()) return;
        _pendingSearchTemplate = VimCharSearch(
          character: '',
          forward: ch == 'f' || ch == 't',
          till: ch == 't' || ch == 'T',
        );
        _await = _Await.findChar;
        _publishHud();
        return;
      case ';':
        if (_blockVisualLineHorizontal()) return;
        _repeatCharSearch(reverse: false);
      case ',':
        if (_blockVisualLineHorizontal()) return;
        _repeatCharSearch(reverse: true);

      // ---- operators ----
      case 'd':
      case 'c':
      case 'y':
      case '>':
      case '<':
        _pushOperator(ch);
      case 'D':
        _applyOperatorRange(VimRange(_cursor, vimLineEnd(_text, _cursor)), 'd');
      case 'C':
        _applyOperatorRange(VimRange(_cursor, vimLineEnd(_text, _cursor)), 'c');
      case 'Y':
        _applyOperatorRange(
          vimLineSpan(_text, _cursor, math.max(1, _takeCount())),
          'y',
        );
      case 'S':
        _applyOperatorRange(
          vimLineSpan(_text, _cursor, math.max(1, _takeCount())),
          'c',
        );
      case 's':
        if (mode.isVisual) {
          _applyOperatorRange(_visualRange(), 'c');
        } else {
          final count = math.max(1, _takeCount());
          _applyOperatorRange(
            VimRange(
              _cursor,
              math.min(vimLineEnd(_text, _cursor), _cursor + count),
            ),
            'c',
          );
        }

      // ---- instant actions ----
      case 'x':
        if (mode.isVisual) {
          _applyOperatorRange(_visualRange(), 'd');
        } else {
          _deleteCharsForward(_takeCount());
        }
      case 'X':
        if (mode.isVisual) {
          _applyOperatorRange(_visualRange(), 'd');
        } else {
          _deleteCharsBackward(_takeCount());
        }
      case 'r':
        _await = _Await.replaceChar;
        _publishHud();
        return;
      case '~':
        _toggleCaseUnderCursor();
      case 'J':
        _joinLines();
      case 'p':
        _paste(before: false);
      case 'P':
        _paste(before: true);
      case 'u':
        if (mode.isVisual) {
          _applyCaseOverRange(_visualRange(), VimCaseOp.toLower);
        } else {
          // Prefer reverting a still-valid snippet expansion (same atom as
          // Ctrl/Cmd+Z). Esc steps the caret back, so this path matches on
          // text only — see SnippetSession.undoLastExpansion.
          final undone = trySnippetUndo?.call() ?? false;
          // Flutter UndoHistory asserts the restored value sticks after
          // onTriggered. Journal/dream/todo `onChanged` handlers call
          // applyListEditing, which would rewrite numbered lists mid-restore
          // and trip `widget.value.value == nextValue`. Suspend those writes
          // for the restore; gate on canUndo so a no-op `u` stays quiet.
          if (!undone && undoController.value.canUndo) {
            suppressListEditingWrites(undoController.undo);
          }
          _clearPending();
        }
      case 'U':
        if (mode.isVisual) {
          _applyCaseOverRange(_visualRange(), VimCaseOp.toUpper);
        } else {
          _clearPending();
        }
      case '.':
        _repeatLastAction();

      // ---- search ----
      case '/':
        _openSearchPrompt(forward: true);
      case '?':
        _openSearchPrompt(forward: false);
      case 'n':
        _jumpToMatch(forward: VimSearchMemory.forward, count: _takeCount());
      case 'N':
        _jumpToMatch(forward: !VimSearchMemory.forward, count: _takeCount());

      default:
        _clearPending();
    }
  }

  /// Consumes the pending count for a motion.
  ///
  /// A count may be typed on either side of an operator, and Vim multiplies
  /// the two: `2dw`, `d2w` and `2d2w` delete two, two and four words. Both
  /// slots are cleared here because the motion that asked for the count is
  /// what completes the command.
  int _takeCount() {
    final motionCount = _count > 0 ? _count : 1;
    final operatorCount = _operatorCount > 0 ? _operatorCount : 1;
    _count = 0;
    _operatorCount = 0;
    return motionCount * operatorCount;
  }

  int? _consumeCount() {
    if (_count == 0) return null;
    final value = _count;
    _count = 0;
    return value;
  }

  int _repeat(int start, int count, int Function(int) step) {
    var offset = start;
    for (var i = 0; i < count; i++) {
      final next = step(offset);
      if (next == offset) break;
      offset = next;
    }
    return offset;
  }

  void _moveVertically(int deltaLines) {
    if (deltaLines == 0) return;
    final text = _text;
    final column = mode == VimMode.visualLine
        ? _visualLineEndColumn
        : math.max(_desiredColumn, vimColumnOf(text, _cursor));
    final target = vimVerticalMove(
      text,
      _cursor,
      deltaLines,
      desiredColumn: column,
    );
    if (_operator != null) {
      _applyOperatorRange(vimLinewiseRange(text, _cursor, target), _operator!);
      return;
    }
    _setCursor(target);
    _desiredColumn = column;
    _clearPending();
  }

  // ==========================================================================
  // Motions feeding operators
  // ==========================================================================

  /// Routes a resolved motion: pending operator → apply over the span; Visual
  /// → extend the selection; otherwise → move the caret.
  void _applyMotion(VimMotion motion) {
    final text = _text;
    final origin = _cursor;
    final destination = motion.offset.clamp(0, text.length);

    final operator = _operator;
    if (operator != null) {
      _desiredColumn = 0;
      final range = _rangeForMotion(origin, destination, motion.kind);
      _applyOperatorRange(range, operator);
      return;
    }

    if (mode == VimMode.visualLine) {
      // Horizontal leftovers (or a no-op on the same line) must not clear the
      // end-of-line sticky column that `j`/`k` rely on.
      if (vimLineStart(text, destination) == vimLineStart(text, origin)) {
        _clearPending();
        return;
      }
      _desiredColumn = _visualLineEndColumn;
      _setCursor(destination);
      _clearPending();
      return;
    }

    _desiredColumn = 0;
    _setCursor(destination);
    _clearPending();
  }

  VimRange _rangeForMotion(int origin, int destination, VimMotionKind kind) {
    final text = _text;
    switch (kind) {
      case VimMotionKind.linewise:
        return vimLinewiseRange(text, origin, destination);
      case VimMotionKind.inclusive:
        final lo = math.min(origin, destination);
        final hi = math.max(origin, destination);
        return VimRange(lo, math.min(text.length, hi + 1));
      case VimMotionKind.exclusive:
        return VimRange(
          math.min(origin, destination),
          math.max(origin, destination),
        );
    }
  }

  // ==========================================================================
  // Operators
  // ==========================================================================

  void _pushOperator(String op) {
    if (mode.isVisual) {
      _applyOperatorRange(_visualRange(), op);
      return;
    }
    if (_operator == op) {
      // Doubled operator (`dd`, `yy`, `>>`): act on whole lines.
      final count = math.max(1, math.max(_operatorCount, _count));
      _count = 0;
      _applyOperatorRange(vimLineSpan(_text, _cursor, count), op);
      return;
    }
    if (_operator != null) {
      _clearPending();
      return;
    }
    _operator = op;
    _operatorCount = _count;
    _count = 0;
    _publishHud();
  }

  void _applyOperatorRange(VimRange rawRange, String op) {
    final text = _text;
    final range = rawRange.normalized();
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    final wasVisual = mode.isVisual;
    final linewise = range.linewise || mode == VimMode.visualLine;

    switch (op) {
      case 'y':
        if (end > start) {
          VimRegister.write(
            _registerPayload(text.substring(start, end), linewise),
            asLines: linewise,
          );
        }
        // Vim leaves the caret at the start of the yanked region.
        if (wasVisual) _setMode(VimMode.normal);
        _setCursor(start);
        _clearPending();

      case 'd':
        _recordDot();
        if (end > start) {
          VimRegister.write(
            _registerPayload(text.substring(start, end), linewise),
            asLines: linewise,
          );
        }
        // Only the delete needs the preceding newline: see
        // vimAbsorbPrecedingNewline. Doing it after the register write keeps
        // that stray newline out of what `p` will replay.
        final cut = linewise
            ? vimAbsorbPrecedingNewline(text, VimRange(start, end))
            : VimRange(start, end);
        final remaining = text.replaceRange(cut.start, cut.end, '');
        final caret = linewise
            ? vimFirstNonBlank(remaining, math.min(cut.start, remaining.length))
            : cut.start;
        if (wasVisual) _setMode(VimMode.normal);
        _writeText(remaining, caret);
        _clearPending();

      case 'c':
        // A linewise change empties the lines but keeps one of them, so the
        // caret has somewhere to type — Vim's `cc`/`cj` behaviour. Trim the
        // range back to the text between the first line's start and the last
        // line's end, dropping the newlines the linewise range included.
        final changeStart = linewise ? vimLineStart(text, start) : start;
        final changeEnd = linewise
            ? vimLineEnd(text, math.max(changeStart, end - 1))
            : end;
        if (changeEnd > changeStart) {
          VimRegister.write(
            text.substring(changeStart, changeEnd),
            asLines: false,
          );
        }
        final afterChange = text.replaceRange(changeStart, changeEnd, '');
        final changeKeys = _dotKeysForChange();
        if (wasVisual) _setMode(VimMode.normal);
        _writeText(afterChange, changeStart, allowLineEnd: true);
        _startInsertCommand(changeStart, keys: changeKeys);

      case '>':
      case '<':
        _recordDot();
        // The count on `3>>` selects three *lines* (already baked into the
        // range by the caller); one press is always one shiftwidth.
        final result = vimShiftLines(
          text,
          start,
          math.max(start, end - 1),
          indent: op == '>',
        );
        if (wasVisual) _setMode(VimMode.normal);
        _writeText(result.text, result.caret);
        _clearPending();

      case 'gu':
      case 'gU':
      case 'g~':
        _applyCaseOverRange(
          VimRange(start, end, linewise: linewise),
          switch (op) {
            'gu' => VimCaseOp.toLower,
            'gU' => VimCaseOp.toUpper,
            _ => VimCaseOp.toggle,
          },
        );

      default:
        _clearPending();
    }
  }

  /// Normalises a linewise register payload to end in a newline, so `p`
  /// always has a whole line to put back even when the text was yanked from
  /// an unterminated final line.
  String _registerPayload(String body, bool linewise) {
    if (!linewise || body.endsWith('\n')) return body;
    return '$body\n';
  }

  void _applyCaseOverRange(VimRange rawRange, VimCaseOp op) {
    _recordDot();
    final text = _text;
    final range = rawRange.normalized();
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    if (end <= start) {
      _clearPending();
      return;
    }
    final replaced = vimApplyCase(text.substring(start, end), op);
    if (mode.isVisual) _setMode(VimMode.normal);
    _writeText(text.replaceRange(start, end, replaced), start);
    _clearPending();
  }

  /// Writes new text and places the caret, in one value update so the field
  /// sees a single edit (one undo entry, one `onChanged`, one spellcheck pass).
  void _writeText(String next, int caret, {bool allowLineEnd = false}) {
    final clamped = allowLineEnd
        ? caret.clamp(0, next.length)
        : vimClampCaret(next, caret);
    _applyValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: clamped),
      ),
    );
  }

  // ==========================================================================
  // Insert-mode entry points
  // ==========================================================================

  /// [affinity] is [TextAffinity.upstream] for append (`a`/`A`): Flutter paints
  /// a caret at a line break — a hard `\n` *or* a soft wrap — on the next
  /// visual line when affinity is the default downstream, which is how `a` on
  /// the last character of a line jumped to the left of the line below.
  void _startInsertCommand(
    int offset, {
    required List<String> keys,
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    _setMode(VimMode.insert);
    _applyValue(
      textController.value.copyWith(
        selection: TextSelection.collapsed(
          offset: offset.clamp(0, _text.length),
          affinity: affinity,
        ),
        composing: TextRange.empty,
      ),
    );
    _insertAnchor = offset.clamp(0, _text.length);
    _insertCommandKeys = keys;
    _count = 0;
    _operator = null;
    _operatorCount = 0;
    _await = _Await.none;
    if (!_replaying) _commandKeys.clear();
    _publishHud();
  }

  /// The key sequence to replay for a `c`-family command. Taken from the keys
  /// typed so far so `ciw`, `c2w` and `cc` each replay as themselves.
  List<String> _dotKeysForChange() =>
      List<String>.unmodifiable(_replaying ? const <String>[] : _commandKeys);

  void _openLine({required bool below}) {
    _recordDot();
    final text = _text;
    if (!isMultiline()) {
      // A single-line field can't hold the newline `o` would insert; treat it
      // as `A`/`I` so the key still does something sensible.
      _startInsertCommand(
        below ? vimLineEnd(text, _cursor) : vimLineStart(text, _cursor),
        keys: below ? const ['o'] : const ['O'],
        affinity: below ? TextAffinity.upstream : TextAffinity.downstream,
      );
      return;
    }
    final insertAt = below
        ? vimLineEnd(text, _cursor)
        : vimLineStart(text, _cursor);
    final next = text.replaceRange(insertAt, insertAt, '\n');
    final caret = below ? insertAt + 1 : insertAt;
    _setMode(VimMode.insert);
    _applyValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );
    _insertAnchor = caret;
    _insertCommandKeys = below ? const ['o'] : const ['O'];
    _clearPending();
  }

  // ==========================================================================
  // Instant actions
  // ==========================================================================

  void _deleteCharsForward(int count) {
    _recordDot();
    final text = _text;
    if (text.isEmpty) {
      _clearPending();
      return;
    }
    final start = _cursor;
    final end = math.min(vimLineEnd(text, start), start + count);
    if (end <= start) {
      _clearPending();
      return;
    }
    VimRegister.write(text.substring(start, end), asLines: false);
    _writeText(text.replaceRange(start, end, ''), start);
    _clearPending();
  }

  void _deleteCharsBackward(int count) {
    _recordDot();
    final text = _text;
    final end = _cursor;
    final start = math.max(vimLineStart(text, end), end - count);
    if (end <= start) {
      _clearPending();
      return;
    }
    VimRegister.write(text.substring(start, end), asLines: false);
    _writeText(text.replaceRange(start, end, ''), start);
    _clearPending();
  }

  void _completeCharSearch(String ch) {
    final template = _pendingSearchTemplate;
    _await = _Await.none;
    _pendingSearchTemplate = null;
    if (template == null || ch.isEmpty) {
      _clearPending();
      return;
    }
    final search = VimCharSearch(
      character: ch,
      forward: template.forward,
      till: template.till,
    );
    _lastCharSearch = search;
    final target = vimFindChar(
      _text,
      _cursor,
      search,
      count: math.max(1, _takeCount()),
    );
    if (target == null) {
      _clearPending();
      return;
    }
    _applyMotion(_charSearchMotion(search, target));
  }

  /// Vim's asymmetry: the forward searches `f`/`t` are inclusive (so `df,`
  /// eats the comma) while the backward `F`/`T` are exclusive (so `dF,` stops
  /// before the character the caret was on).
  VimMotion _charSearchMotion(VimCharSearch search, int target) =>
      search.forward
      ? VimMotion.inclusive(target)
      : VimMotion.exclusive(target);

  VimCharSearch? _lastCharSearch;

  void _repeatCharSearch({required bool reverse}) {
    final last = _lastCharSearch;
    if (last == null) {
      _clearPending();
      return;
    }
    final search = reverse ? last.reversed : last;
    final target = vimFindChar(
      _text,
      _cursor,
      search,
      count: math.max(1, _takeCount()),
      skipAdjacent: true,
    );
    if (target == null) {
      _clearPending();
      return;
    }
    _applyMotion(_charSearchMotion(search, target));
  }

  void _completeReplaceChar(String ch) {
    _await = _Await.none;
    _recordDot();
    final text = _text;

    if (mode.isVisual) {
      final range = _visualRange().normalized();
      final start = range.start.clamp(0, text.length);
      final end = range.end.clamp(start, text.length);
      final replaced = text
          .substring(start, end)
          .split('')
          .map((c) => c == '\n' ? c : ch)
          .join();
      _setMode(VimMode.normal);
      _writeText(text.replaceRange(start, end, replaced), start);
      _clearPending();
      return;
    }

    final count = math.max(1, _takeCount());
    final start = _cursor;
    final end = math.min(vimLineEnd(text, start), start + count);
    if (end <= start) {
      _clearPending();
      return;
    }
    _writeText(text.replaceRange(start, end, ch * (end - start)), end - 1);
    _clearPending();
  }

  void _completeGPrefix(String ch) {
    _await = _Await.none;
    switch (ch) {
      case 'g':
        final count = _consumeCount();
        final target = count != null ? vimOffsetOfLine(_text, count - 1) : 0;
        _applyMotion(VimMotion.linewise(vimFirstNonBlank(_text, target)));
      case '_':
        if (_blockVisualLineHorizontal()) return;
        _applyMotion(VimMotion.inclusive(vimLastNonBlank(_text, _cursor)));
      case 'u':
      case 'U':
      case '~':
        final op = 'g$ch';
        if (mode.isVisual) {
          _applyCaseOverRange(_visualRange(), switch (ch) {
            'u' => VimCaseOp.toLower,
            'U' => VimCaseOp.toUpper,
            _ => VimCaseOp.toggle,
          });
          return;
        }
        if (_operator == op) {
          // `guu` / `gUU` / `g~~`: whole line.
          _applyOperatorRange(
            vimLineSpan(_text, _cursor, math.max(1, _takeCount())),
            op,
          );
          return;
        }
        _operator = op;
        _operatorCount = _count;
        _count = 0;
        _publishHud();
      default:
        _clearPending();
    }
  }

  void _completeTextObject(String ch) {
    _await = _Await.none;
    final operator = _operator;
    final range = vimTextObject(
      _text,
      _cursor,
      object: ch,
      inner: _textObjectInner,
    );
    if (range == null) {
      _clearPending();
      return;
    }
    if (operator == null) {
      // `iw` typed in Visual mode selects the object.
      if (mode.isVisual) {
        _visualAnchor = range.start;
        _visualCursor = math.max(range.start, range.end - 1);
        _applyValue(
          textController.value.copyWith(selection: _visualSelection()),
        );
      }
      _clearPending();
      return;
    }
    _applyOperatorRange(range, operator);
  }

  void _toggleCaseUnderCursor() {
    _recordDot();
    final text = _text;
    if (mode.isVisual) {
      _applyCaseOverRange(_visualRange(), VimCaseOp.toggle);
      return;
    }
    if (text.isEmpty) {
      _clearPending();
      return;
    }
    final count = math.max(1, _takeCount());
    final start = _cursor;
    final end = math.min(vimLineEnd(text, start), start + count);
    if (end <= start) {
      _clearPending();
      return;
    }
    final flipped = vimApplyCase(text.substring(start, end), VimCaseOp.toggle);
    _writeText(text.replaceRange(start, end, flipped), end);
    _clearPending();
  }

  void _joinLines() {
    _recordDot();
    final text = _text;
    if (mode.isVisual) {
      final range = _visualRange().normalized();
      final lines = '\n'
          .allMatches(text.substring(range.start, range.end))
          .length;
      final result = vimJoinLines(text, range.start, math.max(1, lines));
      _setMode(VimMode.normal);
      _writeText(result.text, result.caret);
      _clearPending();
      return;
    }
    final result = vimJoinLines(text, _cursor, math.max(1, _takeCount() - 1));
    _writeText(result.text, result.caret);
    _clearPending();
  }

  /// Puts the unnamed register, or [source] when one is supplied — `<C-v>`
  /// pastes the OS clipboard *through* this without writing it to the
  /// register, so an external copy never displaces your last yank.
  void _paste({
    required bool before,
    String? source,
    bool sourceLinewise = false,
  }) {
    _recordDot();
    final text = _text;
    final payload = source ?? VimRegister.text;
    final putLines = source != null ? sourceLinewise : VimRegister.linewise;
    if (payload.isEmpty) {
      _clearPending();
      return;
    }
    final count = math.max(1, _takeCount());
    final body = payload * count;

    if (mode.isVisual) {
      final range = _visualRange().normalized();
      final start = range.start.clamp(0, text.length);
      final end = range.end.clamp(start, text.length);
      VimRegister.write(text.substring(start, end), asLines: false);
      _setMode(VimMode.normal);
      _writeText(text.replaceRange(start, end, body), start + body.length - 1);
      _clearPending();
      return;
    }

    if (putLines && isMultiline()) {
      // The register always ends in a newline (see _registerPayload), so a
      // linewise put is a whole-line splice above or below the caret's line.
      final chunk = body.endsWith('\n') ? body : '$body\n';
      if (before) {
        final insertAt = vimLineStart(text, _cursor);
        final next = text.replaceRange(insertAt, insertAt, chunk);
        _writeText(next, vimFirstNonBlank(next, insertAt));
        _clearPending();
        return;
      }
      final lineEnd = vimLineEnd(text, _cursor);
      if (lineEnd >= text.length) {
        // Pasting below the final, unterminated line: open the break first
        // and drop the register's own trailing newline so no blank line is
        // left dangling at the bottom.
        final next = '$text\n${chunk.substring(0, chunk.length - 1)}';
        _writeText(next, vimFirstNonBlank(next, text.length + 1));
        _clearPending();
        return;
      }
      final insertAt = lineEnd + 1;
      final next = text.replaceRange(insertAt, insertAt, chunk);
      _writeText(next, vimFirstNonBlank(next, insertAt));
      _clearPending();
      return;
    }

    final flattened = isMultiline() ? body : body.replaceAll('\n', ' ');
    final insertAt = before
        ? _cursor
        : math.min(text.length, text.isEmpty ? 0 : _cursor + 1);
    final next = text.replaceRange(insertAt, insertAt, flattened);
    _writeText(next, insertAt + flattened.length - 1);
    _clearPending();
  }

  Future<void> _pasteFromSystemClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (_disposed) return;
    final payload = data?.text;
    if (payload == null || payload.isEmpty) return;
    _paste(
      before: false,
      source: payload,
      sourceLinewise: payload.endsWith('\n'),
    );
  }

  // ==========================================================================
  // Dot repeat
  // ==========================================================================

  /// Snapshots the keys typed so far as the new `.` target. Called at the top
  /// of every mutating command, while [_commandKeys] still holds the whole
  /// sequence (counts included) and before [_clearPending] wipes it.
  void _recordDot() {
    if (_replaying || _commandKeys.isEmpty) return;
    _lastAction = _DotRecord(List<String>.unmodifiable(_commandKeys), null);
  }

  void _repeatLastAction() {
    final action = _lastAction;
    _count = 0;
    _clearPending();
    if (action == null || action.keys.isEmpty) return;

    _replaying = true;
    try {
      for (final key in action.keys) {
        _handleChar(key);
      }
      final inserted = action.insertedText;
      if (inserted != null && mode == VimMode.insert) {
        final caret = textController.selection.isValid
            ? textController.selection.baseOffset
            : 0;
        final next = _text.replaceRange(caret, caret, inserted);
        _applyValue(
          TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: caret + inserted.length),
          ),
        );
      }
      if (mode == VimMode.insert) {
        _setMode(VimMode.normal);
        final caret = textController.selection.isValid
            ? textController.selection.baseOffset
            : 0;
        _setCursor(_caretAfterInsert(caret));
      }
    } finally {
      _replaying = false;
      _insertAnchor = null;
      _insertCommandKeys = null;
    }
  }

  // ==========================================================================
  // Search (/ ? n N)
  // ==========================================================================

  List<int> _matchesFor(String pattern) {
    final text = _text;
    // `identical` rather than `==`: the controller hands back the same String
    // instance until the value changes, so this is a pointer compare instead
    // of a full memcmp of the document on every keystroke of the `/` prompt.
    // A false miss just recomputes a search that costs microseconds.
    if (identical(_cachedMatchesFor, text) &&
        _cachedMatchesPattern == pattern) {
      return _cachedMatches ?? const [];
    }
    final matches = vimSearchMatches(text, pattern);
    _cachedMatches = matches;
    _cachedMatchesFor = text;
    _cachedMatchesPattern = pattern;
    return matches;
  }

  void _openSearchPrompt({required bool forward}) {
    _clearPending();
    _searchQuery = '';
    _searchForward = forward;
    _searchOriginOffset = _cursor;
    // Whatever the last search marked goes away the moment a new one is
    // opened. Stock Vim leaves the old hits lit until the new pattern
    // replaces them, which means an empty `/` prompt sits over a field still
    // marked up for a search you have already moved on from.
    searchHighlightListenable.value = '';
    searchListenable.value = VimSearchPrompt(
      query: '',
      forward: forward,
      matchCount: 0,
      matchIndex: 0,
    );
  }

  void _cancelSearchPrompt({required bool restoreCaret}) {
    if (searchListenable.value == null) return;
    searchListenable.value = null;
    // The live highlight belonged to the pattern being abandoned.
    searchHighlightListenable.value = '';
    if (restoreCaret) _setCursor(_searchOriginOffset);
    _searchQuery = '';
  }

  KeyEventResult _handleSearchKey(
    KeyEvent event,
    LogicalKeyboardKey key, {
    required bool ctrl,
    required bool alt,
    required bool meta,
  }) {
    if (key == LogicalKeyboardKey.escape ||
        (ctrl && key == LogicalKeyboardKey.bracketLeft)) {
      _cancelSearchPrompt(restoreCaret: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final query = _searchQuery;
      searchListenable.value = null;
      if (query.isNotEmpty) {
        VimSearchMemory.pattern = query;
        VimSearchMemory.forward = _searchForward;
        // Outlives the prompt — see [searchHighlightListenable].
        searchHighlightListenable.value = query;
      } else {
        searchHighlightListenable.value = '';
        _setCursor(_searchOriginOffset);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (_searchQuery.isEmpty) {
        _cancelSearchPrompt(restoreCaret: true);
        return KeyEventResult.handled;
      }
      _searchQuery = _searchQuery.substring(0, _searchQuery.length - 1);
      _refreshSearchPreview();
      return KeyEventResult.handled;
    }
    if (alt || meta || ctrl) return KeyEventResult.ignored;

    final character = event.character;
    if (character == null || character.isEmpty) {
      return KeyEventResult.handled;
    }
    _searchQuery += character;
    _refreshSearchPreview();
    return KeyEventResult.handled;
  }

  /// Vim's `incsearch`: as the pattern grows, the caret previews the first
  /// match ahead of where `/` was pressed. Escape puts it back.
  void _refreshSearchPreview() {
    final query = _searchQuery;
    // Every occurrence lights up as the pattern is typed, not just the one the
    // caret previews — the point of the highlight is seeing where the rest of
    // them are before committing to the search.
    searchHighlightListenable.value = query;
    if (query.isEmpty) {
      searchListenable.value = VimSearchPrompt(
        query: '',
        forward: _searchForward,
        matchCount: 0,
        matchIndex: 0,
      );
      _setCursor(_searchOriginOffset);
      return;
    }
    final matches = _matchesFor(query);
    final index = vimNextMatchIndex(
      matches,
      _searchOriginOffset - (_searchForward ? 0 : 1),
      forward: _searchForward,
    );
    searchListenable.value = VimSearchPrompt(
      query: query,
      forward: _searchForward,
      matchCount: matches.length,
      matchIndex: index == null ? 0 : index + 1,
    );
    if (index != null) _setCursor(matches[index]);
  }

  void _jumpToMatch({required bool forward, int count = 1}) {
    _clearPending();
    final pattern = VimSearchMemory.pattern;
    if (pattern.isEmpty) return;
    // `n` in a field where the highlight was dismissed (or that was never the
    // one searched — the pattern is global) brings the marks back, as Vim's
    // hlsearch does.
    searchHighlightListenable.value = pattern;
    final matches = _matchesFor(pattern);
    if (matches.isEmpty) return;
    var offset = _cursor;
    for (var i = 0; i < math.max(1, count); i++) {
      final index = vimNextMatchIndex(matches, offset, forward: forward);
      if (index == null) return;
      offset = matches[index];
    }
    _setCursor(offset);
  }

  // ==========================================================================
  // Host hooks
  // ==========================================================================

  /// Feeds a single already-decoded character through the Normal/Visual
  /// dispatch table, exactly as a key press would. Exposed for tests, which
  /// drive command sequences directly rather than synthesising raw key events.
  @visibleForTesting
  void handleCharacter(String ch) => _handleChar(ch);
}

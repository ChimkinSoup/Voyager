import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/domain/models/snippet.dart';

/// The tabstops still to visit, published for the dotted-mark overlay.
@immutable
class SnippetMarks {
  const SnippetMarks(this.offsets, this.nextOffset);

  static const SnippetMarks none = SnippetMarks(<int>[], null);

  /// Every remaining tabstop across the whole session stack, ascending by
  /// character offset — painting order, not visit order.
  final List<int> offsets;

  /// The one the next Tab will land on, drawn a shade stronger. Null when the
  /// stack is empty.
  final int? nextOffset;

  bool get isEmpty => offsets.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is SnippetMarks &&
      other.nextOffset == nextOffset &&
      listEquals(other.offsets, offsets);

  @override
  int get hashCode => Object.hash(nextOffset, Object.hashAll(offsets));
}

/// A run of the expansion's *own* characters — the text the snippet inserted,
/// as opposed to whatever the user has since typed into a tabstop.
///
/// A frame starts with one run covering the whole replacement, which every
/// insertion inside it divides in two. Half-open: `[start, end)`.
class _LiteralRun {
  _LiteralRun(this.start, this.end);

  int start;
  int end;
}

/// One expansion's live tabstops and the span of text they belong to.
class _TabstopFrame {
  _TabstopFrame({
    required this.start,
    required this.end,
    required this.stops,
    required this.literals,
  });

  /// Region covering the expanded replacement. [start] is sticky — it only
  /// moves when an edit lands before it — while [end] tracks edits made inside.
  int start;
  int end;

  /// Absolute offsets of the tabstops not yet visited, in **visit** order
  /// (ascending `$n`, which is not necessarily ascending offset).
  final List<int> stops;

  /// The snippet's own characters that are still present, ascending. See
  /// [cutsLiteral] for what they are kept for.
  final List<_LiteralRun> literals;

  bool contains(int offset) => offset >= start && offset <= end;

  /// Whether deleting `[at, end)` would take any of the snippet's own
  /// characters with it.
  ///
  /// Text the user typed into a tabstop is theirs to edit freely; the
  /// backticks, brackets and commas the snippet laid down are the scaffolding
  /// the remaining tabstops are positions *within*, so losing one of those ends
  /// the expansion (SNIPPET.md §4.2).
  bool cutsLiteral(int at, int end) {
    for (final run in literals) {
      if (at < run.end && end > run.start) return true;
    }
    return false;
  }

  /// Re-anchors the runs across an edit that left them all intact.
  void shiftLiterals(int at, int removed, int inserted) {
    final delta = inserted - removed;
    final end = at + removed;
    // Backwards so the run a split appends lands behind the cursor and is not
    // visited again — it is already in post-edit coordinates.
    for (var i = literals.length - 1; i >= 0; i--) {
      final run = literals[i];
      if (end <= run.start) {
        // Entirely before this run, which therefore slides. Text inserted at
        // the boundary belongs to the user, not to the run, so `<=` — the
        // opposite bias to the sticky region [start].
        run.start += delta;
        run.end += delta;
      } else if (at >= run.end) {
        continue;
      } else {
        // Strictly inside, and necessarily an insertion: a deletion reaching
        // into a run is caught by [cutsLiteral] before this runs. The typed
        // text divides one run of snippet characters into two.
        literals.insert(i + 1, _LiteralRun(at + inserted, run.end + delta));
        run.end = at;
      }
    }
  }
}

/// Text-expansion runtime for a single focused field.
///
/// One session is created per eligible field by `VimTextScope`, which also owns
/// the ancestor [Focus] this reads keys from. It is deliberately independent of
/// [VimSession]: snippets work with Vim switched off, and when Vim is on they
/// simply ask [isInsertMode] before expanding anything.
///
/// ### Performance shape
/// The expensive question — "did that keystroke finish a trigger?" — is asked
/// on every character typed into every eligible field in the app, so the
/// **negative** answer is what this is built around. [SnippetIndex] buckets
/// triggers by their final character, so a keystroke that ends no trigger costs
/// one map lookup and stops. Only once a trigger really does match does
/// anything walk the field's text, and only while a tabstop stack is live does
/// anything diff it.
///
/// Nothing here calls `setState`. The only observable output is
/// [marksListenable], which fires whenever the remaining tabstops change — on
/// expansion, on Tab, and on any edit that moves them along the text.
class SnippetSession {
  SnippetSession({
    required this.textController,
    required this.resolveEditableState,
    required this.isInsertMode,
    required SnippetIndex index,
    required SnippetExpandKey expandKey,
    // Not initializing formals: both are rebound by the setters below when the
    // user edits their snippets, so the fields are private and mutable rather
    // than public and final.
    // ignore_for_file: prefer_initializing_formals
  }) : _index = index,
       _expandKey = expandKey {
    _previous = textController.value;
    textController.addListener(_handleEditingChanged);
  }

  final TextEditingController textController;

  /// Resolves the field's [EditableTextState]. Every mutation goes through
  /// [EditableTextState.userUpdateTextEditingValue] for the same reasons Vim's
  /// do: input formatters, `onChanged` (autosave and the journal CRDT depend on
  /// seeing every edit), spellcheck and undo history all hang off that path.
  final EditableTextState? Function() resolveEditableState;

  /// Whether the field is behaving as an insert surface. Always true with Vim
  /// off; `VimMode.insert` only with Vim on. Expansion is gated on it; advancing
  /// an existing tabstop is not, so a session survives a trip through Normal
  /// mode (SNIPPET.md §7).
  final bool Function() isInsertMode;

  SnippetIndex _index;
  SnippetExpandKey _expandKey;

  set index(SnippetIndex value) {
    // By value: a re-read of the settings row rebuilds an equal index, and
    // that is not the user having edited their snippets.
    if (_index == value) return;
    _index = value;
    // Triggers the user just rewrote have nothing to do with a session already
    // on screen, and its offsets were computed from the old list.
    if (_stack.isNotEmpty) reset();
  }

  set expandKey(SnippetExpandKey value) => _expandKey = value;

  final ValueNotifier<SnippetMarks> marksListenable =
      ValueNotifier<SnippetMarks>(SnippetMarks.none);

  final List<_TabstopFrame> _stack = <_TabstopFrame>[];

  /// The value seen at the last notification, for classifying the next one.
  TextEditingValue? _previous;

  /// Set while this session is writing, so its own edits never re-enter the
  /// match path — a snippet whose replacement is one character longer than its
  /// trigger would otherwise expand itself forever.
  bool _applying = false;

  /// The character of the last printable key this field saw, consumed by the
  /// next text change. See [_wasTyped].
  String? _typedChar;

  /// A queued auto-expansion. Expansion cannot run inside the controller
  /// notification that detected it (that would re-enter [EditableTextState]
  /// mid-dispatch), so it is deferred by a microtask — which still lands before
  /// the next frame, so the bare trigger is never painted.
  ({Snippet snippet, TextEditingValue at})? _pending;

  /// The state to put back if the user undoes the expansion that just happened,
  /// and the expanded value that proves nothing has changed since. See
  /// [undoLastExpansion].
  ({TextEditingValue before, TextEditingValue after})? _lastExpansion;

  bool _disposed = false;

  bool get hasSession => _stack.isNotEmpty;

  void dispose() {
    _disposed = true;
    textController.removeListener(_handleEditingChanged);
    marksListenable.dispose();
  }

  /// Called by the host when the field loses focus. Snippet state belongs to
  /// one editing session, exactly like Vim's mode.
  void reset() {
    _pending = null;
    _lastExpansion = null;
    _typedChar = null;
    if (_stack.isEmpty) return;
    _stack.clear();
    _publishMarks();
  }

  // ==========================================================================
  // Keys
  // ==========================================================================

  /// Handles Tab and the expand key, ahead of both the Vim layer and focus
  /// traversal.
  ///
  /// The tag completion popup has already had first refusal by the time this
  /// runs — it owns `focusNode.onKeyEvent`, one level below this scope's node —
  /// so an open popup keeps Tab for accepting a suggestion (SNIPPET.md §4.3).
  KeyEventResult handleKey(KeyEvent event) {
    if (_disposed || event is KeyUpEvent) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;

    // Remember what the user just pressed, so the edit it produces can be told
    // apart from an identical-looking programmatic write — see [_wasTyped].
    // Recorded before the modifier bail-outs below, and only for an unmodified
    // printable key, since that is the only kind that types a character.
    if (!keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed) {
      final character = event.character;
      _typedChar = (character != null && character.isNotEmpty)
          ? character
          : null;
    }

    if (keyboard.isAltPressed) return KeyEventResult.ignored;

    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        key == LogicalKeyboardKey.keyZ) {
      return undoLastExpansion()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.tab) {
      // Shift+Tab is reverse focus traversal and nothing else (decision 9).
      if (keyboard.isShiftPressed) return KeyEventResult.ignored;
      if (_advanceTabstop()) return KeyEventResult.handled;
      if (_expandKey == SnippetExpandKey.tab && _tryManualExpand()) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space &&
        _expandKey == SnippetExpandKey.space) {
      // A successful expansion swallows the space; a miss types one.
      return _tryManualExpand()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  /// Moves the caret to the innermost session's next tabstop.
  ///
  /// The Tab that lands on a session's *last* stop also completes it, and does
  /// not go on to serve the session below or to move focus — the next Tab does
  /// (SNIPPET.md §4.4).
  bool _advanceTabstop() {
    while (_stack.isNotEmpty) {
      final frame = _stack.last;
      final caret = _caret();
      if (frame.stops.isEmpty || caret == null || !frame.contains(caret)) {
        _stack.removeLast();
        continue;
      }
      final target = frame.stops.removeAt(0);
      if (frame.stops.isEmpty) _stack.removeLast();
      _moveCaret(target);
      _publishMarks();
      return true;
    }
    if (marksListenable.value != SnippetMarks.none) _publishMarks();
    return false;
  }

  bool _tryManualExpand() {
    if (!_index.hasManual || !isInsertMode()) return false;
    final value = textController.value;
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    final caret = selection.baseOffset;
    final snippet = _index.matchManual(value.text, caret);
    if (snippet == null) return false;
    _expand(snippet, caret);
    return true;
  }

  /// Puts the trigger back, in one step, when the user undoes the expansion
  /// that just happened.
  ///
  /// Done here rather than left to the field's own undo stack because Flutter's
  /// [UndoHistory] pushes on a 500ms trailing throttle: the typed character and
  /// the expansion it caused always coalesce into one entry, so its undo would
  /// jump back past the trigger instead of restoring it. Guarded on the text
  /// still being exactly what the expansion produced, so any edit in between
  /// hands Ctrl+Z straight back to Flutter.
  ///
  /// [requireMatchingSelection] is the Ctrl+Z rule. Vim Normal `u` passes
  /// false: Esc steps the caret back one character without editing, and that
  /// must not invalidate the atom.
  bool undoLastExpansion({bool requireMatchingSelection = true}) {
    final record = _lastExpansion;
    if (record == null) return false;
    final current = textController.value;
    if (current.text != record.after.text ||
        (requireMatchingSelection &&
            current.selection != record.after.selection)) {
      _lastExpansion = null;
      return false;
    }
    _lastExpansion = null;
    // Everything the expansion created goes with it, outer frames included:
    // their regions were measured against text that is about to change length.
    _stack.clear();
    _applyValue(record.before);
    _publishMarks();
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

    // One key press accounts for at most one text change. Consumed here rather
    // than where it is read so that an edit this session declines to act on
    // still spends it — a stale token must never vouch for a later write.
    final String? typed;
    if (previous.text != value.text) {
      typed = _typedChar;
      _typedChar = null;
    } else {
      typed = null;
    }

    if (_stack.isNotEmpty && previous.text != value.text) {
      _absorbEdit(previous.text, value.text, value.selection);
      // The stops just slid along with the text. Republished immediately or the
      // marks would keep painting at the offsets they held before the edit —
      // pinned to a column the text has moved out of (SNIPPET.md §4.6). Cheap
      // when nothing actually moved: [SnippetMarks] compares by value, so the
      // notifier drops an identical publish.
      _publishMarks();
    }

    if (_shouldConsiderAuto(previous, value, typed)) {
      final caret = value.selection.baseOffset;
      final snippet = _index.matchAuto(value.text, caret);
      // The full-text check is last on purpose: it is the only O(text) step,
      // and it only runs once a trigger has actually matched.
      if (snippet != null &&
          _isSingleInsertAt(previous.text, value.text, caret - 1)) {
        _queueExpand(snippet, value);
        return;
      }
    }

    if (_stack.isNotEmpty) _pruneForCaret(value.selection);
  }

  /// The O(1) gate in front of trigger matching: is this notification even
  /// shaped like "the user typed one character"?
  ///
  /// Rejects paste and every other multi-character insert, deletions (including
  /// the delete-join that would otherwise conjure a trigger out of `e e`),
  /// selection-only notifications, and text arriving mid-IME-composition —
  /// SNIPPET.md §3.1.
  bool _shouldConsiderAuto(
    TextEditingValue previous,
    TextEditingValue value,
    String? typed,
  ) {
    if (!_index.hasAuto) return false;
    if (value.text.length != previous.text.length + 1) return false;
    final selection = value.selection;
    final was = previous.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    if (!was.isValid || !was.isCollapsed) return false;
    if (selection.baseOffset != was.baseOffset + 1) return false;
    if (selection.baseOffset <= 0) return false;
    // A live composing range means the IME is still assembling this text; the
    // committed character arrives with the range collapsed.
    if (value.composing.isValid && !value.composing.isCollapsed) return false;
    if (!_wasTyped(previous, value, typed)) return false;
    return isInsertMode();
  }

  /// Whether the single character this change added was actually *typed*.
  ///
  /// The diff alone cannot tell: a bare `controller.value = …` that inserts one
  /// character at the caret is byte-for-byte what typing produces. The
  /// discriminator is the key event, which the scope's [Focus] hands this
  /// session before the embedder passes the character to the text input plugin
  /// — so a redo, a sync pull or any other programmatic write arrives with no
  /// key to account for it.
  ///
  /// Two things type without a key event, and both are allowed through:
  ///
  ///  * an **IME commit**, which lands the moment a composing range ends
  ///    (SNIPPET.md §3.1 asks for exactly that timing);
  ///  * a **soft keyboard**, which delivers no key events at all — so on those
  ///    platforms the key is not required and the diff has to stand alone.
  bool _wasTyped(
    TextEditingValue previous,
    TextEditingValue value,
    String? typed,
  ) {
    if (typed != null &&
        typed.length == 1 &&
        typed.codeUnitAt(0) ==
            value.text.codeUnitAt(value.selection.baseOffset - 1)) {
      return true;
    }
    if (previous.composing.isValid && !previous.composing.isCollapsed) {
      return true;
    }
    return !_hardwareKeyboardTypes;
  }

  /// Whether a character reaching this field is always preceded by a key event.
  ///
  /// True on the desktop platforms, where there is no soft keyboard to type
  /// without one. On mobile the requirement is dropped rather than breaking
  /// auto-expansion there (SNIPPET.md §7).
  static bool get _hardwareKeyboardTypes => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  /// Whether [next] is [old] with exactly one character inserted at [at].
  ///
  /// Compares code units in place rather than slicing, so a long journal body
  /// costs a scan and no allocation. This is what tells a typed character apart
  /// from a same-length-delta rewrite — a redo, say, which can also grow the
  /// text by one and move the caret by one while changing text elsewhere.
  static bool _isSingleInsertAt(String old, String next, int at) {
    for (var i = 0; i < at; i++) {
      if (old.codeUnitAt(i) != next.codeUnitAt(i)) return false;
    }
    for (var i = at; i < old.length; i++) {
      if (old.codeUnitAt(i) != next.codeUnitAt(i + 1)) return false;
    }
    return true;
  }

  void _queueExpand(Snippet snippet, TextEditingValue at) {
    _pending = (snippet: snippet, at: at);
    scheduleMicrotask(() {
      final pending = _pending;
      _pending = null;
      if (_disposed || pending == null) return;
      // Anything at all happened in between — another keystroke, a sync pull —
      // and this expansion is stale.
      final value = textController.value;
      if (value.text != pending.at.text ||
          value.selection != pending.at.selection) {
        return;
      }
      _expand(pending.snippet, value.selection.baseOffset);
    });
  }

  // ==========================================================================
  // Expansion
  // ==========================================================================

  /// Replaces the trigger ending at [caret] with its parsed replacement and,
  /// when there is more than one tabstop, pushes a session for the rest.
  void _expand(Snippet snippet, int caret) {
    final before = textController.value;
    final text = before.text;
    final start = caret - snippet.trigger.length;
    if (start < 0 || caret > text.length) return;

    final parsed = parseSnippetReplacement(snippet.replacement);
    final next = text.replaceRange(start, caret, parsed.text);
    final stops = <int>[
      for (final stop in parsed.tabstops) start + stop.offset,
    ];
    // No tabstops at all: the caret goes after the replacement and no session
    // is created. Exactly one: the caret lands on it, and there is nothing left
    // for Tab to advance to — also no session (SNIPPET.md §3.5).
    final landing = stops.isEmpty ? start + parsed.text.length : stops.first;

    final after = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: landing),
    );

    // Outer sessions are still live and their offsets were measured against the
    // pre-expansion text — a nested expansion happens *inside* one of them.
    _shiftFrames(start, caret - start, parsed.text.length);

    _applyValue(after);
    _lastExpansion = (before: before, after: after);

    if (stops.length > 1) {
      _stack.add(
        _TabstopFrame(
          start: start,
          end: start + parsed.text.length,
          stops: stops.sublist(1),
          // The whole replacement is the snippet's own; everything the user
          // adds from here divides it. A replacement of nothing but tabstops
          // has no characters to protect.
          literals: <_LiteralRun>[
            if (parsed.text.isNotEmpty)
              _LiteralRun(start, start + parsed.text.length),
          ],
        ),
      );
    }
    _pruneForCaret(after.selection);
    _publishMarks();
  }

  void _moveCaret(int offset) {
    final value = textController.value;
    final clamped = offset.clamp(0, value.text.length);
    if (value.selection.isCollapsed && value.selection.baseOffset == clamped) {
      return;
    }
    _applyValue(
      value.copyWith(
        selection: TextSelection.collapsed(offset: clamped),
        composing: TextRange.empty,
      ),
    );
  }

  void _applyValue(TextEditingValue value) {
    _applying = true;
    try {
      final state = resolveEditableState();
      if (state != null) {
        state.userUpdateTextEditingValue(value, SelectionChangedCause.keyboard);
      } else {
        // Only reachable before the field's first frame, where there is no
        // state to resolve yet.
        textController.value = value;
      }
    } finally {
      _applying = false;
      _previous = textController.value;
    }
  }

  int? _caret() {
    final selection = textController.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    return selection.baseOffset;
  }

  // ==========================================================================
  // Region tracking
  // ==========================================================================

  /// Re-anchors every live region and tabstop across an edit made outside this
  /// session's own writes.
  ///
  /// The edit is recovered as a single replaced span — common prefix, common
  /// suffix, and whatever differs between them. That is not the true minimal
  /// diff for every possible rewrite, but it is exact for the edits that reach
  /// a field with a session open (typing, backspace, a paste at the caret), and
  /// anything it gets wrong lands the caret outside a region, which clears the
  /// session rather than corrupting it.
  ///
  /// [selection] is where the caret ended up, and it is what settles the cases
  /// the two strings cannot. Typing an `e` in front of an `e` produces exactly
  /// the same text as typing one behind it, and the prefix scan always reads it
  /// as the latter — which would leave a tabstop that lived between them
  /// stranded on the wrong side of the character the user just typed, and would
  /// hand ownership of that character to the wrong party (SNIPPET.md §4.2).
  void _absorbEdit(String old, String next, TextSelection selection) {
    var prefix = 0;
    final maxPrefix = old.length < next.length ? old.length : next.length;
    while (prefix < maxPrefix &&
        old.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    final maxSuffix = maxPrefix - prefix;
    while (suffix < maxSuffix &&
        old.codeUnitAt(old.length - 1 - suffix) ==
            next.codeUnitAt(next.length - 1 - suffix)) {
      suffix++;
    }
    final removed = old.length - prefix - suffix;
    final inserted = next.length - prefix - suffix;

    // The split point the caret implies. It can only ever be at or to the left
    // of [prefix] — an edit further right would have left the strings agreeing
    // past the point where they first differ.
    var at = prefix;
    if (selection.isValid && selection.isCollapsed) {
      final candidate = selection.baseOffset - inserted;
      if (candidate >= 0 && candidate < at) {
        // Accepted only if it explains the same text: everything from there to
        // [prefix] has to survive being shifted by the edit. It usually does —
        // that repetition is why the scan overshot in the first place — but a
        // write the caret has nothing to do with must not drag the split with
        // it.
        var explains = true;
        for (var i = candidate; i < prefix; i++) {
          if (old.codeUnitAt(i + removed) != next.codeUnitAt(i + inserted)) {
            explains = false;
            break;
          }
        }
        if (explains) at = candidate;
      }
    }

    _shiftFrames(at, removed, inserted);
  }

  /// Applies "`removed` characters at [at] became `inserted`" to every frame.
  void _shiftFrames(int at, int removed, int inserted) {
    if (_stack.isEmpty) return;
    if (removed == 0 && inserted == 0) return;
    final delta = inserted - removed;
    final end = at + removed;

    int map(int offset) {
      if (offset <= at) return offset;
      if (offset >= end) return offset + delta;
      // Inside the replaced span: the text this offset pointed at is gone.
      return at;
    }

    for (var i = _stack.length - 1; i >= 0; i--) {
      final frame = _stack[i];
      // Dismantling the replacement abandons it. Only this frame goes: an
      // outer expansion whose own characters are untouched still has tabstops
      // that mean something, and so does an inner one — the text a nested
      // snippet laid down is scaffolding to itself and mere content to its
      // parent.
      if (removed > 0 && frame.cutsLiteral(at, end)) {
        _stack.removeAt(i);
        continue;
      }
      frame.shiftLiterals(at, removed, inserted);
      frame.start = map(frame.start);
      frame.end = map(frame.end);
      if (frame.end <= frame.start) {
        // The whole expansion was deleted.
        _stack.removeAt(i);
        continue;
      }
      for (var s = frame.stops.length - 1; s >= 0; s--) {
        final moved = map(frame.stops[s]);
        if (moved < frame.start || moved > frame.end) {
          frame.stops.removeAt(s);
        } else {
          frame.stops[s] = moved;
        }
      }
      if (frame.stops.isEmpty) _stack.removeAt(i);
    }
  }

  /// Drops the sessions the caret has left, innermost first.
  ///
  /// Leaving an inner region for an outer one keeps the outer alive — Tab there
  /// should carry on with the tabstops that are still around the caret. A range
  /// selection (a drag, a Visual selection) is not a caret at all and clears
  /// everything.
  void _pruneForCaret(TextSelection selection) {
    if (_stack.isEmpty) return;
    final before = _stack.length;
    if (!selection.isValid || !selection.isCollapsed) {
      _stack.clear();
    } else {
      final caret = selection.baseOffset;
      while (_stack.isNotEmpty && !_stack.last.contains(caret)) {
        _stack.removeLast();
      }
    }
    if (_stack.length != before) _publishMarks();
  }

  void _publishMarks() {
    if (_disposed) return;
    if (_stack.isEmpty) {
      marksListenable.value = SnippetMarks.none;
      return;
    }
    final offsets = <int>[];
    for (final frame in _stack) {
      offsets.addAll(frame.stops);
    }
    offsets.sort();
    marksListenable.value = SnippetMarks(offsets, _stack.last.stops.first);
  }
}

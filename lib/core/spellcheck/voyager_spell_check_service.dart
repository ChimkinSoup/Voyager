import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/spellcheck/spell_check_suggestions.dart';
import 'package:voyager/core/spellcheck/spell_check_tokenizer.dart';

/// A [SpellCheckService] backed by a bundled dictionary plus user-added
/// custom words, checked purely in Dart. Flutter's built-in
/// [DefaultSpellCheckService] only has a native backend on Android/iOS/macOS
/// (nothing for Windows), so this gives identical behavior on every
/// platform Voyager targets and lets "add custom word" stay a simple local
/// write instead of an OS dictionary integration.
class VoyagerSpellCheckService implements SpellCheckService {
  Set<String> _dictionary = const {};
  Set<String> _customWords = const {};
  Set<String> _known = const {};
  final Map<String, List<String>> _suggestionCache = {};

  /// Bumped whenever the known-word set changes. Callers that keep their own
  /// (text, spans) cache across calls to [checkIncremental] (this class has
  /// no way to reach into arbitrary caller-owned caches itself) should treat
  /// a changed generation as "discard the cache and do a full [checkTextSync]
  /// instead" — a cached span's flagged/known status may no longer be
  /// correct once the dictionary has moved.
  int get generation => _generation.value;

  /// Fires when [generation] changes, i.e. when the dictionary finishes
  /// loading or a custom word is added.
  ///
  /// Checking the generation only tells a caller its cache is stale the next
  /// time it happens to run; widgets that *paint* from that cache also need
  /// to know to run again. SpellCheckSquiggleLayer otherwise rebuilds only
  /// when its controller or focus node notifies, so "Add to dictionary" left
  /// the word's squiggle on screen until some unrelated edit or caret move
  /// woke the layer up.
  Listenable get knownWordsChanged => _generation;

  final ValueNotifier<int> _generation = ValueNotifier<int>(0);

  // Private incremental cache for [fetchSpellCheckSuggestions] specifically:
  // that method's signature is fixed by the [SpellCheckService] interface
  // (Locale, String) -> Future, so it has no way to receive a caller-owned
  // cache the way other callers of [checkIncremental] do. It keeps one for
  // itself instead, exactly as an external caller would.
  String _fetchLastText = '';
  List<SuggestionSpan> _fetchLastSpans = const [];

  void updateDictionary(Set<String> words) {
    _dictionary = words;
    _known = _dictionary.union(_customWords);
    _suggestionCache.clear();
    _fetchLastText = '';
    _fetchLastSpans = const [];
    _generation.value++;
  }

  void updateCustomWords(Set<String> words) {
    _customWords = words;
    _known = _dictionary.union(_customWords);
    _suggestionCache.clear();
    _fetchLastText = '';
    _fetchLastSpans = const [];
    _generation.value++;
  }

  /// Full, from-scratch check: tokenizes and checks every word in [text].
  /// O(length of text) — callers that already have a previous (text, spans)
  /// pair for a value close to this one should prefer [checkIncremental],
  /// which reuses unaffected spans instead of redoing the whole document.
  ///
  /// Used directly for: the very first check of a field (nothing to diff
  /// against yet), and callers that need a guaranteed-complete result right
  /// now regardless of cost (see [forceSpellCheckDisplay] in
  /// spell_check_field_support.dart, used when a field's text is set
  /// programmatically rather than typed, since EditableText never
  /// spellchecks on its own in that case).
  ///
  /// Suggestion strings are *not* computed here by default. Flagging a word
  /// is a set lookup; generating corrections is a Norvig edit-distance
  /// search over a 65k dictionary and will hitch the UI isolate if it runs
  /// on the frame that paints the squiggle (Vim `p`, a paste, Esc into
  /// Normal). Callers that actually display corrections should pass
  /// [includeSuggestions] or use [hydrateSuggestions] on the one span the
  /// user clicked.
  List<SuggestionSpan> checkTextSync(
    String text, {
    bool includeSuggestions = false,
  }) {
    if (_dictionary.isEmpty) return const []; // not loaded yet: flag nothing
    final known = _known;
    final spans = <SuggestionSpan>[];
    for (final range in tokenizeWords(text)) {
      final word = text.substring(range.start, range.end);
      final lower = word.toLowerCase();
      if (known.contains(lower)) continue;
      spans.add(_spanFor(range, lower, includeSuggestions: includeSuggestions));
    }
    return spans;
  }

  /// Incremental check: given the [oldSpans] already known to be correct for
  /// [oldText], returns the spans for [newText] by reusing whatever wasn't
  /// touched by the edit and only re-tokenizing/re-checking the small region
  /// around it — instead of [checkTextSync]'s full O(document length) pass.
  /// A pure function of its arguments (plus the shared dictionary/suggestion
  /// cache): it keeps no memory of [oldText] itself, so it's safe for
  /// multiple independent callers (e.g. [fetchSpellCheckSuggestions] and
  /// SpellCheckSquiggleLayer) to each hold their own (text, spans) pair and
  /// call this without interfering with each other.
  ///
  /// If [oldText] and [newText] differ by more than a plausible single edit
  /// (switching fields, loading a different entry into a reused controller),
  /// [oldSpans] is ignored and this just delegates to [checkTextSync].
  ///
  /// [allowDeferral] (off by default) lets the token still being typed skip
  /// flagging entirely. Production callers must not enable this:
  /// SpellCheckSquiggleLayer already hides the in-progress word via its own
  /// active-edit range, and dropping the span here means a later caret move
  /// or newline-then-retype never re-scans that token — so repeated
  /// misspellings stay unmarked until some unrelated full recheck. Pass
  /// `true` only in tests that specifically cover this opt-in divergence.
  ///
  /// See [checkTextSync] for [includeSuggestions].
  List<SuggestionSpan> checkIncremental({
    required String oldText,
    required List<SuggestionSpan> oldSpans,
    required String newText,
    bool allowDeferral = false,
    bool includeSuggestions = false,
  }) {
    if (_dictionary.isEmpty) return const [];
    if (oldText == newText) return oldSpans;

    final diff = _computeDiff(oldText, newText);
    if (diff == null || !_isIncrementalSafe(oldText, diff)) {
      return checkTextSync(newText, includeSuggestions: includeSuggestions);
    }
    final (prefix, oldEnd, newEnd) = diff;

    // Widen the changed region out to whole-token boundaries (also covering
    // '#' so a #tag isn't cut mid-token either) so re-tokenizing just this
    // window can't produce a token truncated at the window's edge.
    final scanStart = _boundaryBackward(newText, prefix);
    final forwardPad = _boundaryForwardPad(newText, newEnd);
    final scanEnd = newEnd + forwardPad;
    final oldScanEnd = oldEnd + forwardPad;
    final delta = newText.length - oldText.length;

    final spans = <SuggestionSpan>[
      for (final span in oldSpans)
        if (span.range.end <= scanStart) span,
    ];

    // Only a genuine small insertion can be "still being typed". A paste, a
    // Vim put, or any other bulk insert is a finished edit — check it now
    // rather than waiting for the next keystroke that happens to land
    // outside the token. Deletions have nothing to defer.
    final inserted = newEnd - prefix;
    final activeRange = (allowDeferral &&
            inserted > 0 &&
            inserted <= maxDeferredInsertionLength)
        ? TextRange(start: prefix, end: newEnd)
        : null;
    final known = _known;
    for (final range in tokenizeWords(newText.substring(scanStart, scanEnd))) {
      final absRange = TextRange(
        start: range.start + scanStart,
        end: range.end + scanStart,
      );
      if (activeRange != null &&
          absRange.start < activeRange.end &&
          absRange.end > activeRange.start) {
        continue;
      }
      final word = newText.substring(absRange.start, absRange.end);
      final lower = word.toLowerCase();
      if (known.contains(lower)) continue;
      spans.add(
        _spanFor(absRange, lower, includeSuggestions: includeSuggestions),
      );
    }

    for (final span in oldSpans) {
      if (span.range.start >= oldScanEnd) {
        spans.add(
          SuggestionSpan(
            TextRange(start: span.range.start + delta, end: span.range.end + delta),
            span.suggestions,
          ),
        );
      }
    }

    return spans;
  }

  /// Fills in [SuggestionSpan.suggestions] for a span that was flagged
  /// without them. The check hot path skips generation so painting a
  /// squiggle never blocks the UI isolate; the right-click popup is the
  /// one place corrections are actually shown.
  SuggestionSpan hydrateSuggestions(String text, SuggestionSpan span) {
    if (span.suggestions.isNotEmpty) return span;
    final start = span.range.start.clamp(0, text.length);
    final end = span.range.end.clamp(start, text.length);
    if (start >= end) return span;
    final lower = text.substring(start, end).toLowerCase();
    return SuggestionSpan(span.range, _suggestionsFor(lower));
  }

  SuggestionSpan _spanFor(
    TextRange range,
    String lower, {
    required bool includeSuggestions,
  }) {
    return SuggestionSpan(
      range,
      includeSuggestions ? _suggestionsFor(lower) : const <String>[],
    );
  }

  List<String> _suggestionsFor(String lower) {
    return _suggestionCache.putIfAbsent(
      lower,
      () => generateSuggestions(lower, _known),
    );
  }

  /// Insertions longer than this are never treated as "still being typed"
  /// even when [allowDeferral] is true — a paste or Vim put, not a keystroke.
  static const int maxDeferredInsertionLength = 2;

  /// A single keystroke's worth of edit is a handful of characters, so a
  /// large gap between [oldText] and [newText] (switching fields, loading a
  /// different entry into a reused controller) isn't an in-progress word —
  /// treat it as unrelated text and check everything normally rather than
  /// guessing at a nonsensical "changed region".
  static const _maxIncrementalEditLength = 200;

  bool _isIncrementalSafe(String oldText, (int, int, int) diff) {
    final (prefix, oldEnd, newEnd) = diff;
    final changedOld = oldEnd - prefix;
    final changedNew = newEnd - prefix;
    if (changedOld > _maxIncrementalEditLength || changedNew > _maxIncrementalEditLength) {
      return false;
    }
    // A genuine keystroke edit leaves most of the *old* text untouched
    // (typing is almost always a pure insertion). Two short, unrelated
    // texts (e.g. a different entry loaded into a reused controller) can
    // still produce a small *absolute* changed span just because they're
    // both short — the length cap above alone won't catch that — so also
    // require most of the old text to still be present.
    if (oldText.isNotEmpty && changedOld > oldText.length ~/ 2) return false;
    return true;
  }

  /// The (prefix, oldEnd, newEnd) triple describing where [newText] differs
  /// from [oldText]: text before `prefix` and from `oldEnd`/`newEnd` onward
  /// is identical between the two; `old[prefix:oldEnd]` was replaced by
  /// `new[prefix:newEnd]`. Null if the texts are identical.
  (int, int, int)? _computeDiff(String oldText, String newText) {
    if (oldText == newText) return null;
    final maxPrefix = oldText.length < newText.length ? oldText.length : newText.length;
    var prefix = 0;
    while (prefix < maxPrefix && oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }
    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > prefix &&
        newEnd > prefix &&
        oldText.codeUnitAt(oldEnd - 1) == newText.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    return (prefix, oldEnd, newEnd);
  }

  /// Characters that can be part of a word token ([tokenizeWords]'s
  /// `[A-Za-z']` pattern) or a `#tag` ([journalTagPattern], hyphens included so
  /// a multi-word tag isn't cut at one) — used to widen a changed region out to
  /// whole-token boundaries before re-tokenizing just that window.
  static final _boundaryChar = RegExp(r"[A-Za-z0-9_#'-]");

  /// Capped so a pathological run of boundary characters with no real word
  /// break (never happens in real prose) can't make a single edit scan an
  /// unbounded amount of text — defeating the point of checking
  /// incrementally. Worst case is a token accidentally cut at the cap,
  /// which just re-corrects itself on the next edit.
  static const _maxBoundaryScan = 200;

  int _boundaryBackward(String text, int pos) {
    var i = pos;
    final limit = pos - _maxBoundaryScan < 0 ? 0 : pos - _maxBoundaryScan;
    while (i > limit && _boundaryChar.hasMatch(text[i - 1])) {
      i--;
    }
    return i;
  }

  int _boundaryForwardPad(String text, int pos) {
    var i = pos;
    final limit = pos + _maxBoundaryScan > text.length ? text.length : pos + _maxBoundaryScan;
    while (i < limit && _boundaryChar.hasMatch(text[i])) {
      i++;
    }
    return i - pos;
  }

  // Not `async`: the work below is pure synchronous CPU (no real I/O), and
  // returning a [SynchronousFuture] keeps `await` in EditableText's
  // `_performSpellCheck` from deferring by a microtask. That deferral opened
  // a window where the render object's text was dirtied by a stale/unrelated
  // microtask completion while an engine-dispatched pointer packet (e.g. a
  // mouse-hover cursor check) hit-tested it mid-layout-invalidation, tripping
  // "Text layout not available" — see project_flutter_spellcheck_freeze memory.
  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) {
    final spans = checkIncremental(
      oldText: _fetchLastText,
      oldSpans: _fetchLastSpans,
      newText: text,
      allowDeferral: false,
    );
    _fetchLastText = text;
    _fetchLastSpans = spans;
    return SynchronousFuture(spans);
  }
}

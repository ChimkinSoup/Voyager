import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/snippet.dart';

/// The user's snippet list, compiled once into the shape the matcher wants.
///
/// ### Why this exists
/// Matching runs on the keystroke path of every eligible text field in the
/// app, so the cost of *not* matching is what matters — the user is typing
/// prose, and almost every character they type ends no trigger at all. Snippets
/// are therefore bucketed by the **last code unit of their trigger**: a
/// keystroke looks up one small map, finds nothing, and stops. Only when some
/// trigger really does end in the character just typed does anything walk the
/// text.
///
/// Built once per settings change (see `SnippetEnabledScope`) and shared by
/// every field, rather than rebuilt per session or per keystroke.
class SnippetIndex {
  SnippetIndex._(
    this.snippets,
    this._auto,
    this._manual,
    this.hasAuto,
    this.hasManual,
  );

  factory SnippetIndex.from(List<Snippet> snippets) {
    if (snippets.isEmpty) return empty;
    final auto = <int, List<Snippet>>{};
    final manual = <int, List<Snippet>>{};
    for (final snippet in snippets) {
      if (snippet.trigger.isEmpty) continue;
      final bucket = snippet.autoExpand ? auto : manual;
      final unit = snippet.trigger.codeUnitAt(snippet.trigger.length - 1);
      (bucket[unit] ??= <Snippet>[]).add(snippet);
    }
    // Longest first, so the first suffix that matches is the longest one and
    // the walk can stop there — see [_matchIn].
    for (final bucket in [auto.values, manual.values]) {
      for (final list in bucket) {
        list.sort((a, b) => b.trigger.length.compareTo(a.trigger.length));
      }
    }
    return SnippetIndex._(
      List<Snippet>.unmodifiable(snippets),
      auto,
      manual,
      auto.isNotEmpty,
      manual.isNotEmpty,
    );
  }

  static final SnippetIndex empty = SnippetIndex._(
    const <Snippet>[],
    const <int, List<Snippet>>{},
    const <int, List<Snippet>>{},
    false,
    false,
  );

  final List<Snippet> snippets;
  final Map<int, List<Snippet>> _auto;
  final Map<int, List<Snippet>> _manual;

  /// Whether there is anything to match at all, hoisted out of the maps so the
  /// keystroke path can bail on a field read rather than a lookup.
  final bool hasAuto;
  final bool hasManual;

  bool get isEmpty => !hasAuto && !hasManual;

  /// The auto-expand snippet whose trigger ends at [caret], or null.
  ///
  /// [caret] is the offset *after* the character just typed, so the trigger is
  /// a suffix of `text[0, caret)`.
  Snippet? matchAuto(String text, int caret) =>
      hasAuto ? _matchIn(_auto, text, caret) : null;

  /// The manual snippet whose trigger ends at [caret], longest first — the
  /// disambiguation rule for two manual triggers that are suffixes of each
  /// other (`e` and `ee`).
  Snippet? matchManual(String text, int caret) =>
      hasManual ? _matchIn(_manual, text, caret) : null;

  static Snippet? _matchIn(
    Map<int, List<Snippet>> buckets,
    String text,
    int caret,
  ) {
    if (caret <= 0 || caret > text.length) return null;
    final candidates = buckets[text.codeUnitAt(caret - 1)];
    if (candidates == null) return null;
    for (final snippet in candidates) {
      final start = caret - snippet.trigger.length;
      if (start < 0) continue;
      if (!_matchesAt(text, start, snippet.trigger)) continue;
      // Latex Suite's `w`: delimiter before the trigger *and* after the caret.
      // End of field counts as a delimiter (see [isSnippetWordDelimiter]).
      if (snippet.wordBoundary &&
          (!isSnippetWordDelimiter(text, start - 1) ||
              !isSnippetWordDelimiter(text, caret))) {
        continue;
      }
      return snippet;
    }
    return null;
  }

  /// Two indexes are the same index when they were compiled from the same
  /// snippets, however many times the settings row has been re-read since.
  ///
  /// By value rather than by identity because the settings row is re-read from
  /// the database on every `invalidate(settingsProvider)`, which hands out a
  /// fresh [List] of equal [Snippet]s. Compared by identity, that re-read would
  /// look like the user having edited their snippets, and would tear down every
  /// live tabstop session in the app (see `SnippetSession.index`).
  ///
  /// Cheap in the case that matters: the lists are almost always the same
  /// instance, and a user's snippet list is a handful of entries even when
  /// they are not.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SnippetIndex && listEquals(other.snippets, snippets);

  @override
  int get hashCode => Object.hashAll(snippets);

  /// `text[start, start + trigger.length) == trigger`, without allocating the
  /// substring that `String.startsWith` would.
  ///
  /// The last unit is already known to match (it chose the bucket), so the
  /// comparison runs backwards from the one before it — triggers that share a
  /// final character usually differ closer to their end than their start.
  static bool _matchesAt(String text, int start, String trigger) {
    for (var i = trigger.length - 2; i >= 0; i--) {
      if (text.codeUnitAt(start + i) != trigger.codeUnitAt(i)) return false;
    }
    return true;
  }
}

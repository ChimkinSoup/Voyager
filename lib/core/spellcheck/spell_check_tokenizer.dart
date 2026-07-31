import 'package:flutter/widgets.dart';
import 'package:voyager/core/utils/journal_tags.dart';

final _wordPattern = RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*");

/// Word tokens in [text], excluding any token that falls inside a `#tag`
/// span (matched by [journalTagPattern]), since tag vocabulary is
/// user-defined and shouldn't be spellchecked.
List<TextRange> tokenizeWords(String text) {
  final tagRanges = [
    for (final m in journalTagPattern.allMatches(text))
      TextRange(start: m.start, end: m.end),
  ];
  bool insideTag(int start, int end) =>
      tagRanges.any((r) => start < r.end && end > r.start);

  return [
    for (final m in _wordPattern.allMatches(text))
      if (!insideTag(m.start, m.end)) TextRange(start: m.start, end: m.end),
  ];
}

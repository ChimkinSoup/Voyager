import 'package:flutter/widgets.dart';
import 'package:voyager/core/spellcheck/word_token.dart';
import 'package:voyager/core/text/prose_markup.dart';

/// Word tokens in [text], excluding any token that holds a digit (`3D`, `XM6's`
/// — see [runHasDigit]) or falls inside an exclusion zone — a `#tag`, an
/// `` `inline code` `` span, or `$…$` LaTeX
/// (EMPHASIS_FORMATTING.md §6.1). None of the three holds prose the dictionary
/// has any business judging: tag vocabulary is user-defined, code is code, and
/// `$\alpha$` is not a misspelling of anything.
///
/// The tail an **unclosed** backtick opens is deliberately still checked. It
/// is excluded from emphasis parsing (§4.2) and from autocorrect, but one
/// stray backtick taking the squiggles off everything below it in a long entry
/// is a much louder failure than a squiggle inside half-written code.
///
/// [start] and [end] restrict the tokens returned to a window of [text] while
/// zones are still resolved against the whole document, which is the only way
/// a window starting inside `` `…` `` can know it is inside one. Offsets in
/// the result are always absolute.
List<TextRange> tokenizeWords(String text, {int start = 0, int? end}) {
  final zones = [
    for (final zone in ProseMarkup.zonesOf(text))
      if (zone.closed) zone,
  ];

  final scanEnd = end ?? text.length;
  final tokens = <TextRange>[];
  var zone = 0;
  for (final m in wordRunPattern.allMatches(text, start)) {
    if (m.start >= scanEnd) break;
    if (runHasDigit(m[0]!)) continue;
    // Zones come back in document order and so do tokens, so one forward
    // cursor serves both. Testing every token against every zone was
    // quadratic: a heavily tagged entry of a couple of thousand words ran tens
    // of thousands of range comparisons per keystroke, on the UI isolate.
    while (zone < zones.length && zones[zone].end <= m.start) {
      zone++;
    }
    if (zone < zones.length && m.end > zones[zone].start) continue;
    tokens.add(TextRange(start: m.start, end: m.end));
  }
  return tokens;
}

import 'package:voyager/core/spellcheck/word_token.dart';

/// How many bundled matches one query will show. A one-character query matches
/// thousands of words; past a screenful they stop being an answer to "is this
/// word in here?" and start being a list to scroll.
const int dictionarySearchLimit = 100;

/// One query's answer, split by what the user can do with each half: [custom]
/// words are theirs to rename or remove, [bundled] ones are read-only.
class DictionarySearchResult {
  const DictionarySearchResult({
    required this.custom,
    required this.bundled,
    required this.truncated,
    required this.candidates,
    required this.candidatesComplete,
  });

  static const empty = DictionarySearchResult(
    custom: <String>[],
    bundled: <String>[],
    truncated: false,
    candidates: <String>[],
    candidatesComplete: false,
  );

  /// Matching custom words, best match first then A–Z. Never capped: the point
  /// of the list is to reach the user's own words, and there are dozens of
  /// those, not thousands.
  final List<String> custom;

  /// Matching bundled words, most common first, capped at the search limit.
  final List<String> bundled;

  /// Whether matches were left out of [bundled] — the caller says so rather
  /// than letting the list read as the complete answer.
  final bool truncated;

  /// Every bundled word this query matched, in the order the set was scanned.
  ///
  /// Handed back so a caller typing one character at a time can pass it as the
  /// next query's `candidates`: a longer query can only match a subset of what
  /// a shorter one did. Kept caller-side rather than in a cache here, the same
  /// way `VoyagerSpellCheckService.checkIncremental` leaves its (text, spans)
  /// pair to the caller, so two callers can't corrupt each other's memo.
  final List<String> candidates;

  /// Whether [candidates] is the *complete* match list. False when the scan
  /// stopped early, in which case it is a partial answer and must not be
  /// narrowed from.
  final bool candidatesComplete;
}

/// Searches `bundled ∪ custom` for [query], ranked exact → prefix → contains.
///
/// Bundled matches keep the order they appear in `assets/dictionary_en.txt`,
/// which is by descending frequency — so a query of `s` answers with `so`,
/// `she`, `some` rather than the alphabetically first `sa`, `saab`, `saag`.
/// That ordering is also what makes this cheap: the scan stops as soon as the
/// cap is full of prefix matches (nothing found later can outrank them), so a
/// short query reads a few hundred entries instead of all 65k. Only a query
/// too rare to fill the cap pays for a full pass, and its result is complete,
/// so every longer query typed after it narrows that instead (see
/// [DictionarySearchResult.candidates]).
///
/// The exact match is looked up in the set directly rather than waited for in
/// the scan: a rare word can sit far below the cap's worth of commoner words
/// that share its prefix, and "yes, that exact word is known" is the one
/// answer that must never be the thing left out.
DictionarySearchResult searchDictionary({
  required String query,
  required Set<String> bundled,
  required Set<String> custom,
  List<String>? candidates,
  int limit = dictionarySearchLimit,
}) {
  final q = normalizeCustomWord(query);
  // No query is not a query for all 65k words: with nothing typed the list is
  // the user's own words, which is what they came to manage.
  if (q.isEmpty) {
    return DictionarySearchResult(
      custom: custom.toList()..sort(),
      bundled: const <String>[],
      truncated: false,
      candidates: const <String>[],
      candidatesComplete: false,
    );
  }

  final customMatches = _rankCustom(q, custom);

  final matches = <String>[];
  var prefixCount = 0;
  var complete = true;
  for (final word in candidates ?? bundled) {
    if (word.startsWith(q)) {
      matches.add(word);
      if (++prefixCount >= limit) {
        complete = false;
        break;
      }
    } else if (word.contains(q)) {
      matches.add(word);
    }
  }

  final ranked = <String>[];
  var truncated = !complete;
  // A word in both sets would be listed twice; the check is skipped entirely
  // when there are no custom words, which is the common case and the only one
  // where this loop is long.
  final overlapPossible = custom.isNotEmpty;
  if (bundled.contains(q) && !custom.contains(q)) ranked.add(q);
  for (var pass = 0; pass < 2 && ranked.length < limit; pass++) {
    for (final word in matches) {
      if (ranked.length >= limit) {
        truncated = true;
        break;
      }
      if (word == q) continue;
      if (word.startsWith(q) != (pass == 0)) continue;
      if (overlapPossible && custom.contains(word)) continue;
      ranked.add(word);
    }
  }

  return DictionarySearchResult(
    custom: customMatches,
    bundled: ranked,
    truncated: truncated,
    candidates: matches,
    candidatesComplete: complete,
  );
}

/// The custom set ranked the same way, but alphabetically within each rank —
/// the user's own words have no frequency to sort by.
List<String> _rankCustom(String q, Set<String> custom) {
  final prefix = <String>[];
  final contains = <String>[];
  var exact = false;
  for (final word in custom) {
    if (word == q) {
      exact = true;
    } else if (word.startsWith(q)) {
      prefix.add(word);
    } else if (word.contains(q)) {
      contains.add(word);
    }
  }
  prefix.sort();
  contains.sort();
  return [if (exact) q, ...prefix, ...contains];
}

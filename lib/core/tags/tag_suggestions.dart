import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/journal_tags.dart';

/// Which page's tag vocabulary a field draws its suggestions from.
///
/// Pools are deliberately per-page rather than app-wide: a `#groceries` from
/// the finance tracker has nothing to say about a dream entry, and LeetCode's
/// tags arrive wholesale from the API (see `leetcode_track_modal.dart`, which
/// dumps a problem's `topicTags` into the field), so a shared pool would bury
/// hand-written tags under dozens of imported topic slugs.
enum TagScope {
  journal,
  dream,
  finance,
  leetcode,
}

/// The `#tag` token the caret currently sits in.
///
/// [start] indexes the `#` itself and [end] the first character past the
/// token, so `text.replaceRange(start, end, ...)` swaps the whole tag even
/// when the caret is in the middle of it. [query] is only the part *before*
/// the caret — that's what filters the list, matching how every other
/// completion UI behaves when you edit a word from the middle.
typedef ActiveTagToken = ({int start, int end, String query});

const _hashCodeUnit = 0x23;

/// Whether [codeUnit] is a word character.
///
/// Matches [journalTagPattern]'s `\w`, which in Dart is ASCII-only
/// (`[A-Za-z0-9_]`). Written against code units rather than a [RegExp] because
/// this runs on every keystroke of a document that can be thousands of
/// characters long — `text[i]` alone would allocate a one-char [String] per
/// character scanned.
bool _isWordChar(int codeUnit) =>
    (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
    (codeUnit >= 0x41 && codeUnit <= 0x5A) || // A-Z
    (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
    codeUnit == 0x5F; // _

/// Whether [codeUnit] can appear inside a tag body — a word character or the
/// hyphen that joins a multi-word tag's words together.
///
/// A hyphen only counts as part of the tag once a word follows it, so the token
/// this finds is a superset of what [journalTagPattern] will paint by exactly
/// one character: the hyphen you have just typed and not yet typed past. That
/// half-typed tag is the one moment completion matters most, so it's scanned as
/// part of the token rather than treated as the end of one.
bool _isTagChar(int codeUnit) => _isWordChar(codeUnit) || codeUnit == 0x2D; // -

/// Finds the tag token [cursor] sits inside, or null if the caret isn't in one.
///
/// Returns null when the `#` is preceded by a word character (`C#`, `a#b`),
/// which is a sigil in some other word rather than the start of a tag.
ActiveTagToken? activeTagToken(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;

  var wordStart = cursor;
  while (wordStart > 0 && _isTagChar(text.codeUnitAt(wordStart - 1))) {
    wordStart--;
  }

  final hashIndex = wordStart - 1;
  if (hashIndex < 0 || text.codeUnitAt(hashIndex) != _hashCodeUnit) return null;
  // A word character, not a tag character: a hyphen before the `#` belongs to
  // the prose around it ("well-#known"), so it doesn't make the `#` a sigil the
  // way `C#` or `a#b` does.
  if (hashIndex > 0 && _isWordChar(text.codeUnitAt(hashIndex - 1))) return null;

  var end = cursor;
  while (end < text.length && _isTagChar(text.codeUnitAt(end))) {
    end++;
  }

  return (
    start: hashIndex,
    end: end,
    query: text.substring(wordStart, cursor),
  );
}

/// Orders every tag in [tagLists] by how many records carry it, most-used
/// first, breaking ties alphabetically so the list never reshuffles between
/// two equally-used tags.
///
/// Casing is preserved rather than folded: the rest of the app treats `#Work`
/// and `#work` as distinct tags (they get separate colors from
/// [colorForTag]), so collapsing them here would suggest a tag that isn't the
/// one the entry would actually be filed under.
List<String> rankTagsByUsage(Iterable<Iterable<String>> tagLists) {
  final counts = <String, int>{};
  for (final tags in tagLists) {
    for (final tag in tags) {
      if (tag.isEmpty) continue;
      counts.update(tag, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  return counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      if (byCount != 0) return byCount;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
}

/// The suggestions to offer for [query], preserving [pool]'s usage order.
///
/// Matching is case-insensitive prefix matching, so `#C` offers `CC` but
/// `#X` offers nothing. An exact, sole match returns nothing: once you've
/// typed `#CC` in full there is no completion left to make, and leaving the
/// popup up would only swallow the next Enter.
List<String> filterTagSuggestions(
  List<String> pool,
  String query, {
  int limit = 8,
}) {
  final needle = query.toLowerCase();
  final matches = [
    for (final tag in pool)
      if (tag.toLowerCase().startsWith(needle)) tag,
  ];

  if (matches.length == 1 && matches.first.toLowerCase() == needle) {
    return const [];
  }
  return matches.length <= limit ? matches : matches.sublist(0, limit);
}

/// Every tag used on [scope]'s own records, most-used first.
///
/// Kept alive because each pool is a fold over a list the page already has
/// loaded, and the field rebuilds it on every keystroke.
final tagPoolProvider =
    FutureProvider.family<List<String>, TagScope>((ref, scope) async {
  ref.keepAlive();
  switch (scope) {
    case TagScope.journal:
      final entries = await ref.watch(allJournalEntriesProvider.future);
      return rankTagsByUsage(entries.map((e) => e.tags));
    case TagScope.dream:
      final entries = await ref.watch(allDreamEntriesProvider.future);
      return rankTagsByUsage(entries.map((e) => e.tags));
    case TagScope.finance:
      final transactions = await ref.watch(transactionsProvider.future);
      return rankTagsByUsage(transactions.map((t) => t.tags));
    case TagScope.leetcode:
      final problems = await ref.watch(leetcodeProblemsProvider.future);
      return rankTagsByUsage(problems.map((p) => p.tags));
  }
});

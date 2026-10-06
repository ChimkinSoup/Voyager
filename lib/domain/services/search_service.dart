import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/search_fold.dart';
import 'package:voyager/domain/models/journal_models.dart';

class SearchService {
  /// What a query is matched against for [entry]: its title and body as the
  /// results display them — paired formatting markers taken out, so `foobar`
  /// finds `foo**bar**` and `**` finds nothing (BUG-089) — and folded by
  /// [searchFold].
  static String foldEntry(JournalEntry entry) =>
      searchFold('${proseStrip(entry.title)} ${proseStrip(entry.body)}');

  /// Filters [entries] by [tagFilter] (ANDed) and by every token in [query].
  ///
  /// [foldedText] is an optional `entry.id -> [foldEntry]` cache.
  /// Folding here instead allocates a full-body concat *and* a full-body
  /// lowercase for every entry on every call, and the search page calls this
  /// once per keystroke over every entry in the database — on a few thousand
  /// entries that was megabytes of transient string per character typed, on
  /// the UI isolate. Callers that keep a cache pass it; the fold stays here as
  /// the fallback so the service is still correct on its own.
  List<JournalEntry> searchEntries({
    required List<JournalEntry> entries,
    required String query,
    List<String>? tagFilter,
    Map<String, String>? foldedText,
  }) {
    var candidates = entries;
    if (tagFilter != null && tagFilter.isNotEmpty) {
      // Both sides are folded because `extractTags` preserves the author's
      // casing while keyword matching is case-insensitive: searching `#work`
      // used to return nothing for an entry tagged `#Work`, and the query
      // field's own autocomplete would happily suggest the casing the filter
      // then rejected.
      final needles = tagFilter.map(searchFold).toList();
      candidates = candidates.where((e) {
        final own = e.tags.map(searchFold).toSet();
        return needles.every(own.contains);
      }).toList();
    }

    final tokens = query
        .split(RegExp(r'\s+'))
        .map(searchFold)
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return candidates;

    return candidates.where((entry) {
      final haystack = foldedText?[entry.id] ?? foldEntry(entry);
      return tokens.every(haystack.contains);
    }).toList();
  }
}

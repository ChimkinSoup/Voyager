import 'package:voyager/domain/models/journal_models.dart';

class SearchService {
  /// Filters [entries] by [tagFilter] (ANDed) and by every token in [query].
  ///
  /// [foldedText] is an optional `entry.id -> lowercased "title body"` cache.
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
      final needles = tagFilter.map((t) => t.toLowerCase()).toList();
      candidates = candidates.where((e) {
        final own = e.tags.map((t) => t.toLowerCase()).toSet();
        return needles.every(own.contains);
      }).toList();
    }

    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return candidates;

    return candidates.where((entry) {
      final haystack =
          foldedText?[entry.id] ??
          '${entry.title} ${entry.body}'.toLowerCase();
      return tokens.every(haystack.contains);
    }).toList();
  }
}

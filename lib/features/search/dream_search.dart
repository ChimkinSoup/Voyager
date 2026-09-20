import 'package:voyager/domain/models/dream_models.dart';

/// The Search page's dream-journal scope: the query-field command that enters
/// it, and the filter it runs. Pure so both can be tested without pumping the
/// page.

/// The query-field command that switches Search from journal entries to
/// dreams.
const dreamSearchCommand = '/dream';

/// Matches the command only at a word boundary, so `/dreamscape` stays an
/// ordinary query. Case-sensitive: `/Dream` is a query too. Same shape as the
/// Todo page's `/search` (see `todoSearchCommandQuery`).
final _dreamSearchCommandPattern = RegExp('^$dreamSearchCommand(\$| )');

/// The query the dream scope opens with, or null when [text] isn't the
/// `/dream` command at all.
///
/// Returns the empty string for a bare `/dream` (or `/dream `), which enters
/// the scope with no filter rather than doing nothing.
String? dreamSearchCommandQuery(String text) {
  if (!_dreamSearchCommandPattern.hasMatch(text)) return null;
  return text.substring(dreamSearchCommand.length).trimLeft();
}

/// Everything about [entry] a query can match: its title, its body, and its
/// notepad, folded to lower case.
///
/// Folded per call rather than cached the way the journal side caches entry
/// bodies (see `_SearchPageState._foldedText`): that cache exists because the
/// journal corpus is every entry in the database, while dreams are one row a
/// night.
String dreamSearchCorpus(DreamEntry entry) {
  final notes = entry.notes;
  final buffer = StringBuffer(entry.title)
    ..write(' ')
    ..write(entry.body);
  if (notes != null && notes.isNotEmpty) {
    buffer
      ..write(' ')
      ..write(notes);
  }
  return buffer.toString().toLowerCase();
}

/// [entries] filtered by [tagFilter] (ANDed) and by every token in [query],
/// in the order they came in.
///
/// The same semantics as [SearchService.searchEntries] on the journal side:
/// case-insensitive substring matching, every token has to land somewhere in
/// the corpus, and both sides of a tag comparison are folded because
/// `extractTags` preserves the author's casing.
List<DreamEntry> filterDreamEntries({
  required List<DreamEntry> entries,
  required String query,
  List<String>? tagFilter,
}) {
  var candidates = entries;
  if (tagFilter != null && tagFilter.isNotEmpty) {
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
    final haystack = dreamSearchCorpus(entry);
    return tokens.every(haystack.contains);
  }).toList();
}

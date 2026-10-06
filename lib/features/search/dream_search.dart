import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/search_fold.dart';
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
/// notepad, as displayed (paired formatting markers taken out, BUG-089) and
/// folded by [searchFold].
///
/// The Search page caches it per dream (see `_SearchPageState._dreamFolded`):
/// [proseStrip] parses each dream with markers, and the filter runs per
/// keystroke.
String dreamSearchCorpus(DreamEntry entry) {
  final notes = entry.notes;
  final buffer = StringBuffer(proseStrip(entry.title))
    ..write(' ')
    ..write(proseStrip(entry.body));
  if (notes != null && notes.isNotEmpty) {
    buffer
      ..write(' ')
      ..write(proseStrip(notes));
  }
  return searchFold(buffer.toString());
}

/// [entries] filtered by [tagFilter] (ANDed) and by every token in [query],
/// in the order they came in.
///
/// The same semantics as [SearchService.searchEntries] on the journal side:
/// substring matching on [searchFold]ed text, every token has to land somewhere in
/// the corpus, and both sides of a tag comparison are folded because
/// `extractTags` preserves the author's casing.
List<DreamEntry> filterDreamEntries({
  required List<DreamEntry> entries,
  required String query,
  List<String>? tagFilter,
  Map<String, String>? foldedText,
}) {
  var candidates = entries;
  if (tagFilter != null && tagFilter.isNotEmpty) {
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
    final haystack = foldedText?[entry.id] ?? dreamSearchCorpus(entry);
    return tokens.every(haystack.contains);
  }).toList();
}

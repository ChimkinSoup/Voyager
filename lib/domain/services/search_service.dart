import 'package:voyager/domain/models/journal_models.dart';

class SearchService {
  List<JournalEntry> searchEntries({
    required List<JournalEntry> entries,
    required String query,
    List<String>? tagFilter,
  }) {
    if (tagFilter != null && tagFilter.isNotEmpty) {
      return entries
          .where((e) => tagFilter.every((tag) => e.tags.contains(tag)))
          .toList();
    }

    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return entries;

    return entries.where((entry) {
      final haystack = '${entry.title} ${entry.body}'.toLowerCase();
      return tokens.every(haystack.contains);
    }).toList();
  }
}

import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';

/// One entry that matched a filter, carrying the tab and section it came from.
///
/// The parents ride along because results render grouped by tab → section: a
/// hit in Python has to be visibly a hit in Python, since "which language did
/// I write that in" is the question search is actually answering.
class LeetCodeCheatHit {
  const LeetCodeCheatHit({
    required this.tab,
    required this.section,
    required this.entry,
  });

  final LeetCodeCheatTab tab;
  final LeetCodeCheatSection section;
  final LeetCodeCheatEntry entry;
}

/// Every entry matching [query], across **all** tabs, in tab → section →
/// entry order.
///
/// Matches `command`, `label`, `description` and `complexity`,
/// case-insensitively, on a plain substring — the same shape the Review Deck's
/// keyword filter uses. A
/// blank query matches nothing rather than everything: the caller shows the
/// unfiltered sheet instead of running this at all.
List<LeetCodeCheatHit> searchLeetCodeCheatSheet(
  LeetCodeCheatSheetData data,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];

  final hits = <LeetCodeCheatHit>[];
  for (final tab in data.tabs) {
    for (final section in data.sectionsOf(tab.id)) {
      for (final entry in data.entriesOf(section.id)) {
        if (_matches(entry, needle)) {
          hits.add(LeetCodeCheatHit(tab: tab, section: section, entry: entry));
        }
      }
    }
  }
  return hits;
}

/// How many entries each tab contributes to [hits], keyed by tab id.
///
/// What the tab strip shows beside each name while a filter is active, so the
/// user can see a hit is waiting in Java without switching to it first. Tabs
/// with no hits are absent rather than mapped to zero.
Map<String, int> leetCodeCheatMatchCounts(List<LeetCodeCheatHit> hits) {
  final counts = <String, int>{};
  for (final hit in hits) {
    counts[hit.tab.id] = (counts[hit.tab.id] ?? 0) + 1;
  }
  return counts;
}

bool _matches(LeetCodeCheatEntry entry, String needle) {
  if (entry.command.toLowerCase().contains(needle)) return true;
  if (entry.description.toLowerCase().contains(needle)) return true;
  final label = entry.label;
  if (label != null && label.toLowerCase().contains(needle)) return true;
  final complexity = entry.complexity;
  return complexity != null && complexity.toLowerCase().contains(needle);
}

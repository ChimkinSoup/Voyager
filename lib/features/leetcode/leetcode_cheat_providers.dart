import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';

/// The whole cheat sheet in one snapshot: every live tab, the live sections
/// under each, and the live entries under each of those.
///
/// One read rather than a provider family per section. The sheet is a personal
/// reference doc — a few hundred entries at the outside — and search has to
/// see every tab at once anyway (§4.5), so the shape that answers the
/// hardest question is the one worth holding.
class LeetCodeCheatSheetData {
  const LeetCodeCheatSheetData({
    required this.tabs,
    required this.sectionsByTab,
    required this.entriesBySection,
  });

  const LeetCodeCheatSheetData.empty()
    : tabs = const [],
      sectionsByTab = const {},
      entriesBySection = const {};

  /// By position. The first is what a stale [AppSettings.leetCodeCheatLastTabId]
  /// falls back to.
  final List<LeetCodeCheatTab> tabs;

  /// Keyed by tab id, each list by position. A tab with no sections is absent
  /// rather than mapped to an empty list.
  final Map<String, List<LeetCodeCheatSection>> sectionsByTab;

  /// Keyed by section id, each list by position.
  final Map<String, List<LeetCodeCheatEntry>> entriesBySection;

  bool get isEmpty => tabs.isEmpty;

  List<LeetCodeCheatSection> sectionsOf(String tabId) =>
      sectionsByTab[tabId] ?? const [];

  List<LeetCodeCheatEntry> entriesOf(String sectionId) =>
      entriesBySection[sectionId] ?? const [];

  /// The tab [id] names, or the first tab when it names none — a stale id is
  /// expected rather than exceptional (§5.5).
  LeetCodeCheatTab? resolveTab(String? id) {
    if (tabs.isEmpty) return null;
    for (final tab in tabs) {
      if (tab.id == id) return tab;
    }
    return tabs.first;
  }
}

final leetCodeCheatSheetProvider = FutureProvider<LeetCodeCheatSheetData>((
  ref,
) async {
  ref.keepAlive();
  final repository = ref.watch(leetCodeRepositoryProvider);
  final tabs = await repository.listCheatTabs();
  // Both list calls already join through live parents, so nothing here has to
  // re-check that a section's tab or an entry's section survived.
  final sections = await repository.listCheatSections();
  final entries = await repository.listCheatEntries();

  final sectionsByTab = <String, List<LeetCodeCheatSection>>{};
  for (final section in sections) {
    (sectionsByTab[section.tabId] ??= []).add(section);
  }
  final entriesBySection = <String, List<LeetCodeCheatEntry>>{};
  for (final entry in entries) {
    (entriesBySection[entry.sectionId] ??= []).add(entry);
  }

  return LeetCodeCheatSheetData(
    tabs: tabs,
    sectionsByTab: sectionsByTab,
    entriesBySection: entriesBySection,
  );
});

/// Whether the cheat sheet is on screen.
///
/// Read by the session and cram pages to put their own keyboard and swipe
/// handling down while it is up (§7). The sheet's route sits on the *root*
/// navigator, above the shell's, so neither `ModalRoute.isCurrent` nor
/// `subtreeIsVisible` notices it — this flag is what those gates consult
/// instead, the same job `mediaLightboxIsOpen` does for the image viewer.
final leetCodeCheatSheetOpenProvider = StateProvider<bool>((_) => false);

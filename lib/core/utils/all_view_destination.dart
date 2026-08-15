/// Shared "where does a new item go?" logic for the Todo and Journal pages.
///
/// Both pages have an all-view ("All tasks" / "All journals") that spans every
/// list, so the composer in that view has no list of its own to write to. The
/// two pages used to answer that question with separate, subtly different
/// fallback chains; this is the single implementation they now both call.
library;

/// Resolves the list/journal a newly created item belongs to.
///
/// In priority order:
///  1. [currentId] — the list the page is filtered to, which the all-view
///     deliberately leaves pointing at whatever was last opened.
///  2. [lastViewedId] — the id restored from settings, which covers the case
///     where the app reopened straight into the all-view.
///  3. [legacyId] — the built-in default list, if it still exists.
///  4. The first available id.
///
/// Each candidate is only accepted if it is still present in [availableIds];
/// a list can be deleted between the id being recorded and this being called.
/// Returns null only when [availableIds] is empty.
String? resolveNewItemTarget({
  required String? currentId,
  required String? lastViewedId,
  required String legacyId,
  required List<String> availableIds,
}) {
  if (availableIds.isEmpty) return null;
  for (final candidate in [currentId, lastViewedId, legacyId]) {
    if (candidate != null && availableIds.contains(candidate)) return candidate;
  }
  return availableIds.first;
}

/// Trims a list/journal name for use inside composer text like
/// `Add task to Reading`, which sits in panes that go as narrow as 180px.
/// Truncating here rather than relying on ellipsis keeps the surrounding
/// widgets (a bare `Text` in a min-width `Row`, a single-line field hint)
/// from overflowing.
String shortDestinationName(String name, {int maxLength = 14}) {
  final trimmed = name.trim();
  if (trimmed.length <= maxLength) return trimmed;
  return '${trimmed.substring(0, maxLength - 1).trimRight()}…';
}

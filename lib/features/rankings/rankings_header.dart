import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/caps_lock/caps_lock_caret_indicator.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_icons.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

/// The page's top tier (§2.1): which category is open, how much of it is
/// ranked, and the two status chips that narrow the queue.
///
/// Every number here is measured against the *scoped* pool — the search box
/// and the filter popover already applied — so the band answers a question
/// about what is on screen rather than about the category as a whole (§3.1).
class RankingsStatsBand extends StatelessWidget {
  const RankingsStatsBand({
    super.key,
    required this.category,
    required this.categories,
    required this.stats,
    required this.activeStatuses,
    required this.onStatusTapped,
    required this.onSelectCategory,
  });

  final RankingCategory category;

  /// Active categories only — archived ones are reached through Manage (§2.2).
  final List<RankingCategory> categories;

  final ({int ranked, int inProgress, int queued, double? average}) stats;
  final Set<RankingStatus> activeStatuses;
  final ValueChanged<RankingStatus> onStatusTapped;
  final ValueChanged<String> onSelectCategory;

  @override
  Widget build(BuildContext context) {
    final accent = paletteColor(category.colorValue, context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: SizedBox(
        height: 76,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CategoryTrigger(
              category: category,
              categories: categories,
              onSelect: onSelectCategory,
            ),
            const SizedBox(width: 22),
            _HeroStats(stats: stats, category: category),
            const SizedBox(width: 22),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _StatusChips(
                  accent: accent,
                  inProgress: stats.inProgress,
                  queued: stats.queued,
                  activeStatuses: activeStatuses,
                  onStatusTapped: onStatusTapped,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The category picker, reduced to one word and an icon (§2.2).
///
/// A strip of pills spent a whole tier of the page on a control that is used
/// once a session and, for most lists, holds fewer than five things. The
/// popover puts that choice where the eye already is — beside the numbers the
/// category is being judged by — and hands the tier back to the list.
class _CategoryTrigger extends StatelessWidget {
  const _CategoryTrigger({
    required this.category,
    required this.categories,
    required this.onSelect,
  });

  final RankingCategory category;
  final List<RankingCategory> categories;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = paletteColor(category.colorValue, context);

    return Center(
      child: Builder(
        builder: (buttonContext) => Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => showContextualPopover<void>(
              context: context,
              buttonContext: buttonContext,
              accentColor: accent,
              width: 240,
              builder: (context) => _CategoryMenu(
                selectedId: category.id,
                categories: categories,
                onSelect: onSelect,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    rankingCategoryIcon(category.iconKey),
                    size: 18,
                    color: accent,
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    PhosphorIconsRegular.caretDown,
                    size: 12,
                    color: accent.withValues(alpha: 0.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryMenu extends ConsumerWidget {
  const _CategoryMenu({
    required this.selectedId,
    required this.categories,
    required this.onSelect,
  });

  final String selectedId;
  final List<RankingCategory> categories;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          for (final entry in categories)
            InkWell(
              onTap: () {
                onSelect(entry.id);
                Navigator.of(context).pop();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      rankingCategoryIcon(entry.iconKey),
                      size: 15,
                      color: paletteColor(entry.colorValue, context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: entry.id == selectedId
                              ? FontWeight.w700
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${ref.watch(rankingParentsProvider(entry.id)).valueOrNull?.length ?? 0}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The count and the average, each in a slot wide enough for the longest value
/// it can hold (§3.1) — scoring one more entry never nudges the chips beside
/// them sideways.
class _HeroStats extends StatelessWidget {
  const _HeroStats({required this.stats, required this.category});

  final ({int ranked, int inProgress, int queued, double? average}) stats;
  final RankingCategory category;

  static const _countWidth = 64.0;
  static const _averageWidth = 56.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final average = stats.average;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: _countWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${stats.ranked}',
                maxLines: 1,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'ranked',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: _averageWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                average == null
                    ? '—'
                    : formatRankingScore(
                        roundRankingScore(
                          average,
                          scoreMax: category.parentScoreMax,
                          precision: category.parentScorePrecision,
                        ),
                      ),
                maxLines: 1,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1,
                  color: paletteColor(category.colorValue, context),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'avg',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The two status chips, in Jobs' idiom: a tap toggles one, and an empty set
/// means "show everything" rather than "show nothing" (§3.2).
class _StatusChips extends StatelessWidget {
  const _StatusChips({
    required this.accent,
    required this.inProgress,
    required this.queued,
    required this.activeStatuses,
    required this.onStatusTapped,
  });

  final Color accent;
  final int inProgress;
  final int queued;
  final Set<RankingStatus> activeStatuses;
  final ValueChanged<RankingStatus> onStatusTapped;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusChip(
          label: 'In progress',
          count: inProgress,
          color: accent,
          selected: activeStatuses.contains(RankingStatus.inProgress),
          onTap: () => onStatusTapped(RankingStatus.inProgress),
        ),
        const SizedBox(width: 6),
        _StatusChip(
          label: 'Queued',
          count: queued,
          color: accent,
          selected: activeStatuses.contains(RankingStatus.queued),
          onTap: () => onStatusTapped(RankingStatus.queued),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Filter the queue by $label',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: selected
                  ? color.withValues(alpha: 0.20)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? color : color.withValues(alpha: 0.35),
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.labelSmall),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The second tier (§4): the search box, the two menus and the way into
/// Manage.
///
/// Nothing here appears or disappears as the page is narrowed — no Clear
/// button that shows up the moment a filter is on and takes the pills with it
/// as it goes. Clearing lives inside the filter popover, where the filters
/// themselves are.
class RankingsToolbar extends StatelessWidget {
  const RankingsToolbar({
    super.key,
    required this.category,
    required this.searchController,
    required this.onQueryChanged,
    required this.filters,
    required this.onFiltersChanged,
    required this.onSortChanged,
    required this.tags,
    required this.onManage,
  });

  final RankingCategory category;
  final TextEditingController searchController;
  final ValueChanged<String> onQueryChanged;
  final RankingFilters filters;
  final ValueChanged<RankingFilters> onFiltersChanged;

  /// The sort key and direction, written straight onto the category so the
  /// choice syncs with it.
  final void Function(RankingSortMode mode, String? fieldId, bool ascending)
  onSortChanged;

  final List<String> tags;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = paletteColor(category.colorValue, context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              // Taller than the 32 the page used to give it (§4): the search
              // box is the control the page is driven from, and it was the
              // shortest thing in the row.
              height: 38,
              // Not under a [VimTextScope] like the app's prose fields, so the
              // Caps Lock mark is opted into by hand here.
              child: CapsLockCaretIndicator(
                child: TextField(
                  controller: searchController,
                  onChanged: onQueryChanged,
                  style: theme.textTheme.bodySmall,
                  // Focused in the category's colour, like every other control
                  // on this page: the box sits inside one category's chrome,
                  // and the app's own accent read as a stray colour there.
                  cursorColor: accent,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search titles, notes, units and tags',
                    prefixIcon: const Icon(
                      PhosphorIconsRegular.magnifyingGlass,
                      size: 14,
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    border: const OutlineInputBorder(),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: accent.withValues(alpha: 0.95),
                        width: 1.8,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (buttonContext) => SelectorPill(
              label: _sortLabel(category),
              icon: category.sortAscending
                  ? PhosphorIconsRegular.sortAscending
                  : PhosphorIconsRegular.sortDescending,
              dense: true,
              accentColor: accent,
              onTap: () => showContextualPopover<void>(
                context: context,
                buttonContext: buttonContext,
                accentColor: accent,
                width: 240,
                builder: (context) => _SortMenu(onSortChanged: onSortChanged),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Builder(
            builder: (buttonContext) => SelectorPill(
              label: filters.hasPopoverFilters ? 'Filtered' : 'Filter',
              icon: PhosphorIconsRegular.funnel,
              dense: true,
              isActive: filters.hasPopoverFilters,
              accentColor: accent,
              onTap: () => showContextualPopover<void>(
                context: context,
                buttonContext: buttonContext,
                accentColor: accent,
                width: 260,
                builder: (context) => _FilterMenu(
                  tags: tags,
                  onChanged: onFiltersChanged,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: 'Manage categories and templates',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onManage,
            icon: const Icon(PhosphorIconsRegular.slidersHorizontal),
          ),
        ],
      ),
    );
  }
}

/// The Sort pill's label for [category]'s current key.
String _sortLabel(RankingCategory category) {
  switch (category.sortMode) {
    case RankingSortMode.overallScore:
      return 'Score';
    case RankingSortMode.updatedAt:
      return 'Updated';
    case RankingSortMode.createdAt:
      return 'Created';
    case RankingSortMode.customField:
      final field = category.parentTemplate
          .where((f) => f.id == category.sortFieldId)
          .firstOrNull;
      return field?.label ?? 'Field';
  }
}

/// The sort menu, reading the category out of the provider rather than off the
/// widget that opened it (§4.2).
///
/// A popover is a pushed route: nothing in the page's own rebuild reaches it,
/// so a menu handed a category by value would still be showing the sort the
/// user just changed away from — the checkmark stuck on the old key and the
/// direction row still saying "Ascending" after it had been turned off.
class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.onSortChanged});

  final void Function(RankingSortMode mode, String? fieldId, bool ascending)
  onSortChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = ref.watch(rankingActiveCategoryProvider);
    if (category == null) return const SizedBox.shrink();
    final fields = category.activeParentTemplate;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SortTile(
          label: 'Overall score',
          selected: category.sortMode == RankingSortMode.overallScore,
          onTap: () => onSortChanged(
            RankingSortMode.overallScore,
            null,
            category.sortAscending,
          ),
        ),
        _SortTile(
          label: 'Last updated',
          selected: category.sortMode == RankingSortMode.updatedAt,
          onTap: () => onSortChanged(
            RankingSortMode.updatedAt,
            null,
            category.sortAscending,
          ),
        ),
        _SortTile(
          label: 'Created',
          selected: category.sortMode == RankingSortMode.createdAt,
          onTap: () => onSortChanged(
            RankingSortMode.createdAt,
            null,
            category.sortAscending,
          ),
        ),
        for (final field in fields)
          _SortTile(
            label: field.label,
            selected:
                category.sortMode == RankingSortMode.customField &&
                category.sortFieldId == field.id,
            onTap: () => onSortChanged(
              RankingSortMode.customField,
              field.id,
              category.sortAscending,
            ),
          ),
        const Divider(height: 1),
        _SortTile(
          label: category.sortAscending ? 'Ascending' : 'Descending',
          selected: false,
          trailing: Icon(
            category.sortAscending
                ? PhosphorIconsRegular.sortAscending
                : PhosphorIconsRegular.sortDescending,
            size: 14,
          ),
          onTap: () => onSortChanged(
            category.sortMode,
            category.sortFieldId,
            !category.sortAscending,
          ),
        ),
      ],
    );
  }
}

class _SortTile extends StatelessWidget {
  const _SortTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : null,
                ),
              ),
            ),
            if (selected)
              const Icon(PhosphorIconsRegular.check, size: 14)
            else
              ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Score range, images and tags — the narrowing that is not a status (§4.1).
///
/// [tags] is the category's *structured* vocabulary only. A `#tag` that lives
/// in someone's notes is still searchable, but it has no chip on any row, and
/// a filter nothing visible answers to is a filter you cannot reason about.
///
/// Reads its state from the provider for the same reason [_SortMenu] does: a
/// slider handed its value once would snap back to it on the next drag.
class _FilterMenu extends ConsumerWidget {
  const _FilterMenu({required this.tags, required this.onChanged});

  final List<String> tags;
  final ValueChanged<RankingFilters> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final category = ref.watch(rankingActiveCategoryProvider);
    final filters = ref.watch(rankingFiltersProvider);
    if (category == null) return const SizedBox.shrink();

    final max = category.parentScoreMax.toDouble();
    final start = filters.scoreMin ?? 0;
    final end = filters.scoreMax ?? max;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Text(
            'Score ${formatRankingScore(start)}–${formatRankingScore(end)}',
            style: theme.textTheme.labelSmall,
          ),
        ),
        RangeSlider(
          values: RangeValues(start, end),
          min: 0,
          max: max,
          // One division per step of the entry overall's precision, so a
          // bound the slider can reach is always a score an entry can hold
          // (§8.4).
          divisions:
              (category.parentScoreMax /
                      rankingScoreStep(category.parentScorePrecision))
                  .round(),
          onChanged: (values) => onChanged(
            filters.copyWith(
              scoreMin: values.start,
              scoreMax: values.end,
              clearScoreMin: values.start == 0,
              clearScoreMax: values.end == max,
            ),
          ),
        ),
        const Divider(height: 1),
        _CheckTile(
          label: 'Has images',
          value: filters.hasImages,
          onChanged: (checked) =>
              onChanged(filters.copyWith(hasImages: checked)),
        ),
        if (tags.isNotEmpty) ...[
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final tag in tags)
                  _CheckTile(
                    // Bare, not `#tag`: these are the classification tags the
                    // rows print, and the hash would read them as the note
                    // tags this list deliberately leaves out (§4.3).
                    label: tag,
                    value: filters.tag == tag,
                    onChanged: (checked) => onChanged(
                      checked
                          ? filters.copyWith(tag: tag)
                          : filters.copyWith(clearTag: true),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (filters.hasPopoverFilters) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: GlassButton(
                dense: true,
                label: 'Clear filters',
                onPressed: () => onChanged(filters.withoutPopoverFilters()),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            VoyagerCheckbox(
              value: value,
              onChanged: onChanged,
              celebrateOnComplete: false,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/edit_side_panel_host.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_category_dialog.dart';
import 'package:voyager/features/rankings/rankings_edit_panel.dart';
import 'package:voyager/features/rankings/rankings_gallery.dart';
import 'package:voyager/features/rankings/rankings_header.dart';
import 'package:voyager/features/rankings/rankings_manage_sheet.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';
import 'package:voyager/features/rankings/rankings_row.dart';
import 'package:voyager/features/sync/sync_conflict_banner.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';

/// Personal ranking lists: categories of entries, split into what has a score
/// and what does not.
///
/// The split is the page's whole shape. An entry with an overall score is
/// ranked and sorts against every other ranked entry; one without is still
/// being queued or worked through, and sorts by the rules that suit that. No
/// row is ever in both, and nothing stores which section a row is in.
class RankingsPage extends ConsumerStatefulWidget {
  const RankingsPage({super.key});

  @override
  ConsumerState<RankingsPage> createState() => _RankingsPageState();
}

class _RankingsPageState extends ConsumerState<RankingsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _panelController;
  late final Animation<double> _panelAnimation;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _panelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _panelAnimation = CurvedAnimation(
      parent: _panelController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _panelController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _openPanel(String id) {
    ref.read(rankingSelectedParentProvider.notifier).state = id;
    _panelController.forward();
  }

  void _closePanel() {
    _panelController.reverse().then((_) {
      if (!mounted) return;
      ref.read(rankingSelectedParentProvider.notifier).state = null;
    });
  }

  Future<void> _persistEditSidePanelWidth(double? width) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final settings = await settingsRepo.getSettings();
    if (settings.editSidePanelWidth == width) return;
    await settingsNotifier.saveSettings(
      width == null
          ? settings.copyWith(clearEditSidePanelWidth: true)
          : settings.copyWith(editSidePanelWidth: width),
    );
  }

  /// Switching categories takes the editor with it: the entry it was open on
  /// is not in the new list, so the panel would collapse to nothing while the
  /// list beside it stayed narrowed around a panel that is no longer there.
  /// Snapped rather than animated — the whole list is being replaced under it.
  void _dropPanelOnCategoryChange() {
    if (ref.read(rankingSelectedParentProvider) == null &&
        _panelController.value == 0) {
      return;
    }
    ref.read(rankingSelectedParentProvider.notifier).state = null;
    _panelController.value = 0;
  }

  /// Everything that narrows or arranges one category's list belongs to that
  /// category, and goes when it does.
  ///
  /// Carried across, a tag filter emptied the next category with no box left
  /// to untick, a score range out of 10 handed a 5-point slider values past
  /// its max, and a field sort hid every unit's drag handle.
  void _resetOnCategoryChange() {
    ref.read(rankingFiltersProvider.notifier).state = RankingFilters.none;
    ref.read(rankingSearchQueryProvider.notifier).state = '';
    _searchController.clear();
    ref.read(rankingChildSortProvider.notifier).state = (
      sort: RankingChildSort.saved,
      fieldId: null,
    );
    _dropPanelOnCategoryChange();
  }

  @override
  Widget build(BuildContext context) {
    // The resolved category rather than the selection: archiving or deleting
    // the first category changes what is shown while the selection stays null.
    // Deferred, because a provider written during build throws.
    ref.listen<String?>(rankingActiveCategoryProvider.select((c) => c?.id), (
      previous,
      next,
    ) {
      if (previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resetOnCategoryChange();
      });
    });
    final categoriesAsync = ref.watch(rankingCategoriesProvider);
    final categories = categoriesAsync.valueOrNull ?? const <RankingCategory>[];
    final active = [
      for (final category in categories)
        if (!category.isArchived) category,
    ];

    // Null selection means "the first one", so a cold open lands somewhere
    // without having to write a choice the user did not make.
    final selectedId = ref.watch(rankingSelectedCategoryProvider);
    final category =
        categories.where((c) => c.id == selectedId).firstOrNull ??
        active.firstOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: category == null || category.isArchived
          ? null
          : GlassButton(
              tooltip: 'Add an entry',
              label: 'Add',
              icon: const Icon(PhosphorIconsRegular.plus),
              onPressed: () => _createParent(category),
            ),
      body: SafeArea(
        child: categoriesAsync.when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('$error')),
          data: (_) => Column(
            children: [
              const SyncConflictBanner(),
              if (category == null)
                Expanded(
                  child: _EmptyState(
                    icon: PhosphorIconsRegular.star,
                    title: 'No categories yet',
                    message:
                        'A category is one kind of thing you rank — shows, '
                        'restaurants, anything with a list.',
                    actionLabel: 'Create a category',
                    onAction: _createCategory,
                  ),
                )
              else
                Expanded(
                  child: _CategoryBody(
                    category: category,
                    categories: active,
                    searchController: _searchController,
                    panelAnimation: _panelAnimation,
                    storedPanelWidth: ref
                        .watch(settingsProvider)
                        .valueOrNull
                        ?.editSidePanelWidth,
                    onPanelWidthCommitted: (width) =>
                        unawaited(_persistEditSidePanelWidth(width)),
                    onOpenPanel: _openPanel,
                    onClosePanel: _closePanel,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createCategory() async {
    final categories =
        ref.read(rankingCategoriesProvider).valueOrNull ??
        const <RankingCategory>[];
    final result = await showRankingCategoryDialog(context);
    if (result == null) return;
    final created = await RankingsActions(ref).createCategory(
      name: result.name,
      colorValue: result.color,
      iconKey: result.iconKey,
      sortOrder: rankingNextCategorySortOrder(categories),
    );
    if (!mounted) return;
    ref.read(rankingSelectedCategoryProvider.notifier).state = created.id;
  }

  Future<void> _createParent(RankingCategory category) async {
    final title = await showPromptNameDialog(
      context,
      title: 'New entry',
      label: 'Title',
    );
    if (title == null || title.trim().isEmpty) return;
    final parents = await ref.read(rankingParentsProvider(category.id).future);
    final created = await RankingsActions(ref).createParent(
      categoryId: category.id,
      title: title,
      // Bottom of the queue: creating an entry never displaces one already
      // waiting there.
      queueSortOrder: parents.isEmpty
          ? 0
          : parents
                    .map((parent) => parent.queueSortOrder)
                    .reduce((a, b) => a > b ? a : b) +
                1,
    );
    if (!mounted) return;
    _openPanel(created.id);
  }
}

/// One category's chrome, its two sections, and the editor panel beside them.
class _CategoryBody extends ConsumerWidget {
  const _CategoryBody({
    required this.category,
    required this.categories,
    required this.searchController,
    required this.panelAnimation,
    required this.storedPanelWidth,
    required this.onPanelWidthCommitted,
    required this.onOpenPanel,
    required this.onClosePanel,
  });

  final RankingCategory category;
  final List<RankingCategory> categories;
  final TextEditingController searchController;
  final Animation<double> panelAnimation;
  final double? storedPanelWidth;
  final ValueChanged<double?> onPanelWidthCommitted;
  final ValueChanged<String> onOpenPanel;
  final VoidCallback onClosePanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The open entry left the list — deleted from its row menu, or by a sync
    // pull — and took the panel's only close button with it, leaving the list
    // narrowed beside a blank column. Only a settled read counts: a new entry's
    // panel opens before the reload that carries the entry has landed.
    ref.listen(rankingParentsProvider(category.id), (_, next) {
      final selectedId = ref.read(rankingSelectedParentProvider);
      if (selectedId == null || next.isLoading || !next.hasValue) return;
      if (next.requireValue.any((parent) => parent.id == selectedId)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => onClosePanel());
    });
    // The lists alone, not the load state around them: a refresh first
    // announces itself carrying the old list, and watching the whole value
    // rebuilt every row for that, then again a frame later for the new one.
    final parents =
        ref.watch(
          rankingParentsProvider(
            category.id,
          ).select((parents) => parents.valueOrNull),
        ) ??
        const <RankingParent>[];
    final childrenByParent =
        ref.watch(
          rankingChildrenByParentProvider(
            category.id,
          ).select((children) => children.valueOrNull),
        ) ??
        const <String, List<RankingChild>>{};
    final withImages =
        ref.watch(rankingDocumentIdsWithImagesProvider).valueOrNull ??
        const <String>{};
    final query = ref.watch(rankingSearchQueryProvider);
    final filters = ref.watch(rankingFiltersProvider);
    final selectedParentId = ref.watch(rankingSelectedParentProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;

    // The pool the band's numbers are measured against: the search box and the
    // filter popover, but *not* the chips (§5.2). A chip that counted itself
    // would read zero the moment it was switched on.
    final pool = filterRankingParents(
      parents,
      childrenByParent: childrenByParent,
      query: query,
      filters: filters.withoutStatuses(),
      documentIdsWithImages: withImages,
    );
    final stats = rankingCategoryStats(pool);

    final unranked = filterUnrankedByStatus(
      sortUnrankedParents(pool),
      filters.statuses,
    );
    final ranked = sortRankedParents(
      pool,
      sortMode: category.sortMode,
      sortFieldId: category.sortFieldId,
      ascending: category.sortAscending,
    );
    // A constrained score range says nothing about an entry that has no score
    // at all, so the queue steps out of the answer entirely rather than
    // sitting under a heading that half applies to it (§5.1).
    final showQueue = !filters.hasScoreRange && unranked.isNotEmpty;

    final collapsedIds =
        settings?.rankingsCollapsedQueueCategories ?? const <String>[];
    final queueCollapsed = collapsedIds.contains(category.id);

    return Column(
      children: [
        RankingsStatsBand(
          category: category,
          categories: categories,
          stats: stats,
          activeStatuses: filters.statuses,
          onStatusTapped: (status) {
            final next = {...filters.statuses};
            if (!next.remove(status)) next.add(status);
            ref.read(rankingFiltersProvider.notifier).state = filters.copyWith(
              statuses: next,
            );
          },
          onSelectCategory: (id) =>
              ref.read(rankingSelectedCategoryProvider.notifier).state = id,
        ),
        RankingsToolbar(
          category: category,
          searchController: searchController,
          onQueryChanged: (value) =>
              ref.read(rankingSearchQueryProvider.notifier).state = value,
          filters: filters,
          onFiltersChanged: (value) =>
              ref.read(rankingFiltersProvider.notifier).state = value,
          onSortChanged: (mode, fieldId, ascending) =>
              RankingsActions(ref).saveCategory(
                category.copyWith(
                  sortMode: mode,
                  sortFieldId: fieldId,
                  clearSortFieldId: fieldId == null,
                  sortAscending: ascending,
                ),
              ),
          tags: rankingTags(parents),
          onManage: () => showRankingsManageSheet(
            context,
            ref,
            initialCategoryId: category.id,
          ),
        ),
        if (category.isArchived) const _ArchivedBanner(),
        Expanded(
          child: EditSidePanelHost(
            animation: panelAnimation,
            listMinWidth: EditSidePanelMetrics.rankingsListMinWidth,
            storedWidth: storedPanelWidth,
            onWidthCommitted: onPanelWidthCommitted,
            list: parents.isEmpty
                ? _EmptyState(
                    icon: PhosphorIconsRegular.listPlus,
                    title: 'Nothing in ${category.name} yet',
                    message:
                        'Add something you mean to get to. It waits in '
                        'the queue until you give it a score.',
                  )
                : ranked.isEmpty && !showQueue
                ? const _EmptyState(
                    icon: PhosphorIconsRegular.magnifyingGlass,
                    title: 'Nothing matches',
                    message:
                        'Try a different search, or clear the filters.',
                  )
                : _Sections(
                    category: category,
                    unranked: unranked,
                    ranked: ranked,
                    showQueue: showQueue,
                    queueCollapsed: queueCollapsed,
                    onToggleQueue: () =>
                        _toggleQueue(ref, settings, collapsedIds),
                    childrenByParent: childrenByParent,
                    selectedId: selectedParentId,
                    onOpen: onOpenPanel,
                  ),
            panel: _panel(selectedParentId, parents, childrenByParent),
          ),
        ),
      ],
    );
  }

  Widget? _panel(
    String? selectedParentId,
    List<RankingParent> parents,
    Map<String, List<RankingChild>> childrenByParent,
  ) {
    final selected = parents
        .where((parent) => parent.id == selectedParentId)
        .firstOrNull;
    if (selected == null) return null;
    return RankingsEditPanel(
      key: ValueKey(selected.id),
      parent: selected,
      category: category,
      children: childrenByParent[selected.id] ?? const <RankingChild>[],
      tagSuggestions: rankingTagSuggestions(parents),
      readOnly: category.isArchived,
      onClose: onClosePanel,
    );
  }

  Future<void> _toggleQueue(
    WidgetRef ref,
    AppSettings? settings,
    List<String> collapsedIds,
  ) async {
    if (settings == null) return;
    final next = [...collapsedIds];
    if (!next.remove(category.id)) next.add(category.id);
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(
          settings.copyWith(rankingsCollapsedQueueCategories: next),
        );
  }
}

class _Sections extends StatefulWidget {
  const _Sections({
    required this.category,
    required this.unranked,
    required this.ranked,
    required this.showQueue,
    required this.queueCollapsed,
    required this.onToggleQueue,
    required this.childrenByParent,
    required this.selectedId,
    required this.onOpen,
  });

  final RankingCategory category;
  final List<RankingParent> unranked;
  final List<RankingParent> ranked;
  final bool showQueue;
  final bool queueCollapsed;
  final VoidCallback onToggleQueue;
  final Map<String, List<RankingChild>> childrenByParent;
  final String? selectedId;
  final ValueChanged<String> onOpen;

  @override
  State<_Sections> createState() => _SectionsState();
}

class _SectionsState extends State<_Sections> {
  /// The row last built for each entry, handed back as the same object while
  /// nothing it was built from has changed.
  ///
  /// Flutter skips an element whose new widget is the very one it already
  /// has, and nothing short of that stops a rebuild. An edit re-reads the
  /// whole list, so every entry arrives as a new object; without this, adding
  /// one tag rebuilt every row on the page.
  final _rows = <String, _Row>{};

  _Row _row(RankingParent parent, {int? rank, bool showRankSlot = false}) {
    final children =
        widget.childrenByParent[parent.id] ?? const <RankingChild>[];
    final isSelected = parent.id == widget.selectedId;
    final cached = _rows[parent.id];
    if (cached != null &&
        identical(cached.category, widget.category) &&
        identical(cached.children, children) &&
        cached.isSelected == isSelected &&
        cached.rank == rank &&
        cached.showRankSlot == showRankSlot &&
        cached.onOpen == widget.onOpen &&
        rankingParentsMatch(cached.parent, parent)) {
      return cached;
    }
    return _rows[parent.id] = _Row(
      key: ValueKey(parent.id),
      parent: parent,
      category: widget.category,
      children: children,
      isSelected: isSelected,
      onOpen: widget.onOpen,
      rank: rank,
      showRankSlot: showRankSlot,
    );
  }

  @override
  Widget build(BuildContext context) {
    final category = widget.category;
    final unranked = widget.unranked;
    final ranked = widget.ranked;
    final showQueue = widget.showQueue;
    final queueCollapsed = widget.queueCollapsed;
    final live = {
      for (final parent in unranked) parent.id,
      for (final parent in ranked) parent.id,
    };
    _rows.removeWhere((id, _) => !live.contains(id));

    // Ranks are a fact about the score order, so they only mean anything while
    // the list is *in* score order (§6.3).
    final showRanks = category.sortMode == RankingSortMode.overallScore;
    final ranks = showRanks
        ? rankingDisplayRanks(ranked)
        : List<int?>.filled(ranked.length, null);

    // One saved offset per category, rather than one shared by all of them.
    // The key changing across a category switch is what does the work: it
    // remounts the scroll view, so the new position restores from this
    // category's own slot instead of inheriting the pixels the previous
    // category happened to be sitting at (which a shorter list then clamps to
    // its bottom, losing both places). Any scrollable nested under here is now
    // a descendant of a [PageStorageKey] and needs a [ScrollOffsetIsolate] —
    // see `_UnrankedList`.
    return VoyagerScrollView(
      key: PageStorageKey<String>('rankings-sections-${category.id}'),
      padding: const EdgeInsets.only(bottom: 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showQueue) ...[
            _SectionHeader(
              label: 'Queue',
              count: unranked.length,
              collapsed: queueCollapsed,
              onToggleCollapsed: widget.onToggleQueue,
            ),
            if (!queueCollapsed)
              _UnrankedList(
                category: category,
                parents: unranked,
                rowFor: _row,
              ),
          ],
          if (ranked.isNotEmpty) ...[
            _SectionHeader(label: 'Ranked', count: ranked.length),
            for (var i = 0; i < ranked.length; i++)
              _row(ranked[i], rank: ranks[i], showRankSlot: showRanks),
          ] else if (showQueue && !queueCollapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 26, 26, 8),
              child: Text(
                'Nothing ranked yet. Give an entry an overall score and it '
                'moves down here.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The unranked section, drag-reorderable across its queued rows only.
///
/// In-progress and starred rows are ordered by rules of their own, so they get
/// no handle: dragging one would move it to a position the list is not
/// keeping, and it would spring back on the next rebuild.
class _UnrankedList extends ConsumerWidget {
  const _UnrankedList({
    required this.category,
    required this.parents,
    required this.rowFor,
  });

  final RankingCategory category;
  final List<RankingParent> parents;

  /// [_SectionsState._row], so a queued row is reused the same way a ranked
  /// one is.
  final Widget Function(RankingParent parent) rowFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Nested in the page scroll view, so it must not share its saved
    // offset — see [ScrollOffsetIsolate].
    return ScrollOffsetIsolate(
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: parents.length,
        onReorderItem: (oldIndex, newIndex) {
          final queuedIds = rankingQueueOrderAfterDrag(
            parents,
            oldIndex,
            newIndex,
          );
          if (queuedIds == null) return;
          RankingsActions(ref).reorderQueue(queuedIds);
        },
        itemBuilder: (context, index) {
          final parent = parents[index];
          final row = rowFor(parent);
          return rankingIsQueueDraggable(parent) && !category.isArchived
              ? ReorderableDelayedDragStartListener(
                  key: ValueKey(parent.id),
                  index: index,
                  child: row,
                )
              : KeyedSubtree(key: ValueKey(parent.id), child: row);
        },
      ),
    );
  }
}

class _Row extends ConsumerWidget {
  const _Row({
    super.key,
    required this.parent,
    required this.category,
    required this.children,
    required this.isSelected,
    required this.onOpen,
    this.rank,
    this.showRankSlot = false,
  });

  final RankingParent parent;
  final RankingCategory category;

  /// This entry's own list, not the category's map: [_SectionsState._row]
  /// compares it by identity, and the map is replaced whenever any entry's
  /// children are re-read.
  final List<RankingChild> children;
  final bool isSelected;
  final ValueChanged<String> onOpen;
  final int? rank;
  final bool showRankSlot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RankingsRow(
      parent: parent,
      category: category,
      children: children,
      isSelected: isSelected,
      readOnly: category.isArchived,
      rank: rank,
      showRankSlot: showRankSlot,
      onTap: () => onOpen(parent.id),
      onToggleStar: () => RankingsActions(ref).toggleStar(parent.id),
      onScoreChanged: (score) =>
          RankingsActions(ref).setOverallScore(parent.id, score),
      // Set, never toggled (§6.4): re-clicking the active tag leaves the
      // filter alone rather than dropping it out from under the pointer.
      onTagTapped: (tag) {
        final filters = ref.read(rankingFiltersProvider);
        if (filters.tag == tag) return;
        ref.read(rankingFiltersProvider.notifier).state = filters.copyWith(
          tag: tag,
        );
      },
      menuItems: () => _menuItems(context, ref, children),
    );
  }

  /// The row's context menu (§7.3). Everything that only makes sense on one
  /// side of the split is absent on the other, and an archived category keeps
  /// nothing but the way into the pictures.
  List<ContextMenuItem> _menuItems(
    BuildContext context,
    WidgetRef ref,
    List<RankingChild> children,
  ) {
    final actions = RankingsActions(ref);
    final readOnly = category.isArchived;
    final hasImages =
        category.imagesOnParent ||
        (category.imagesOnChild && children.isNotEmpty);

    return [
      if (!readOnly)
        ContextMenuItem(
          label: parent.starred ? 'Unpin' : 'Pin to top',
          icon: parent.starred
              ? PhosphorIconsFill.star
              : PhosphorIconsRegular.star,
          onTap: () => actions.toggleStar(parent.id),
        ),
      if (!readOnly && !parent.isRanked)
        ContextMenuItem(
          label: 'Status',
          icon: PhosphorIconsRegular.circleDashed,
          children: [
            for (final status in RankingStatus.values)
              ContextMenuItem(
                label: status == RankingStatus.inProgress
                    ? 'In progress'
                    : 'Queued',
                trailing: parent.status == status
                    ? const Icon(PhosphorIconsRegular.check, size: 13)
                    : null,
                onTap: () => actions.setStatus(parent.id, status),
              ),
          ],
        ),
      if (!readOnly && parent.isRanked)
        ContextMenuItem(
          label: 'Clear score',
          icon: PhosphorIconsRegular.eraser,
          onTap: () => actions.setOverallScore(parent.id, null),
        ),
      if (hasImages)
        ContextMenuItem(
          label: 'Open gallery',
          icon: PhosphorIconsRegular.images,
          onTap: () => showRankingsEntryGallery(
            context,
            ref,
            parent: parent,
            children: children,
          ),
        ),
      if (!readOnly)
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => confirmDeleteRankingParent(
            context,
            ref,
            parent,
            childCount: children.length,
            childUnitLabel: category.childUnitLabel,
          ),
        ),
    ];
  }
}

/// A section heading (§6.4): sentence case, muted, and — for the queue — the
/// chevron that folds it away.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.count,
    this.collapsed,
    this.onToggleCollapsed,
  });

  final String label;
  final int count;

  /// Null on a section that does not collapse, which is what leaves the
  /// chevron off it entirely.
  final bool? collapsed;
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final heading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '($count)',
          style: theme.textTheme.labelSmall?.copyWith(
            color: muted.withValues(alpha: 0.7),
          ),
        ),
        // After the count, not before the label: a chevron in front of the
        // queue would indent its heading past 'Ranked', which has none.
        if (collapsed != null) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: collapsed! ? -0.25 : 0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: Icon(
              PhosphorIconsRegular.caretDown,
              size: 12,
              color: muted,
            ),
          ),
        ],
      ],
    );

    return Padding(
      // Roomier above than below, so the gap between the queue block and the
      // ranked one reads as a break rather than as more list (§6.4).
      //
      // The tappable heading carries its own 4px of hover padding, taken back
      // out of the left inset here so its label starts on the same pixel as a
      // plain heading's.
      padding: EdgeInsets.fromLTRB(
        onToggleCollapsed == null ? 26 : 22,
        22,
        26,
        6,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: onToggleCollapsed == null
            ? heading
            : Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onToggleCollapsed,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: heading,
                  ),
                ),
              ),
      ),
    );
  }
}

class _ArchivedBanner extends StatelessWidget {
  const _ArchivedBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Text(
        'Archived — read only. Unarchive it in Manage categories to edit.',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 32,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              GlassButton(onPressed: onAction, label: actionLabel, dense: true),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/caps_lock/caps_lock_caret_indicator.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/jobs_stage_colors.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';

/// One popup for everything the Jobs page configures: pipeline stages,
/// company category colours, and archive seasons.
Future<void> showJobsManageSheet(BuildContext context, WidgetRef ref) async {
  await showVoyagerDialog<void>(
    context: context,
    builder: (context) => const _JobsManageDialog(),
  );
  ref.invalidate(jobStagesProvider);
  ref.invalidate(jobCategoriesProvider);
  ref.invalidate(jobCompaniesProvider);
  ref.invalidate(jobSeasonsProvider);
  ref.invalidate(jobApplicationsProvider);
}

enum _ManageTab { stages, categories, seasons }

class _JobsManageDialog extends ConsumerStatefulWidget {
  const _JobsManageDialog();

  @override
  ConsumerState<_JobsManageDialog> createState() => _JobsManageDialogState();
}

class _JobsManageDialogState extends ConsumerState<_JobsManageDialog> {
  var _tab = _ManageTab.stages;

  JobsActions get _actions => JobsActions(ref);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manage jobs'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_ManageTab>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              segments: const [
                ButtonSegment(
                  value: _ManageTab.stages,
                  icon: Icon(PhosphorIconsRegular.flowArrow, size: 15),
                  label: Text('Stages'),
                ),
                ButtonSegment(
                  value: _ManageTab.categories,
                  icon: Icon(PhosphorIconsRegular.palette, size: 15),
                  label: Text('Categories'),
                ),
                ButtonSegment(
                  value: _ManageTab.seasons,
                  icon: Icon(PhosphorIconsRegular.archive, size: 15),
                  label: Text('Seasons'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (set) {
                if (set.isNotEmpty) setState(() => _tab = set.first);
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: switch (_tab) {
                _ManageTab.stages => _StagesTab(actions: _actions),
                _ManageTab.categories => _CategoriesTab(actions: _actions),
                _ManageTab.seasons => _SeasonsTab(actions: _actions),
              },
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context),
          label: 'Close',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stages
// ---------------------------------------------------------------------------

class _StagesTab extends ConsumerWidget {
  const _StagesTab({required this.actions});

  final JobsActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stages = ref.watch(jobStagesProvider).valueOrNull;
    final applications =
        ref.watch(jobApplicationsProvider).valueOrNull ??
        const <JobApplication>[];
    if (stages == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final usageByStatus = <String, int>{};
    for (final application in applications) {
      usageByStatus[application.status] =
          (usageByStatus[application.status] ?? 0) + 1;
    }
    final stageColors = JobStageColors(
      stages: stages,
      fallback: theme.colorScheme.primary,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Drag to reorder. Order is display order only — an application can '
          'move to any stage at any time. Tap a swatch to set the colour its '
          'capsules are drawn in.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          // One dialog route holds this list and the sheet's other scroll
          // views, so a remounted one would otherwise adopt this list's saved
          // offset — see [ScrollOffsetIsolate].
          child: ScrollOffsetIsolate(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: stages.length,
              // onReorderItem, not onReorder: it already adjusts newIndex for
              // the item removed at oldIndex, so no off-by-one correction here.
              onReorderItem: (oldIndex, newIndex) {
                final ids = [for (final stage in stages) stage.id];
                ids.insert(newIndex, ids.removeAt(oldIndex));
                actions.reorderStages(ids);
              },
              itemBuilder: (context, index) {
                final stage = stages[index];
                final inUse = usageByStatus[stage.name] ?? 0;
                return ListTile(
                  key: ValueKey(stage.id),
                  dense: true,
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: const Icon(
                          PhosphorIconsRegular.dotsSixVertical,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StageSwatch(
                        color: stageColors.forStage(stage),
                        explicit: stageColors.isExplicit(stage),
                        onTap: () => _recolor(context, ref, stage),
                      ),
                    ],
                  ),
                  title: Text(stage.name, style: theme.textTheme.bodySmall),
                  subtitle: Text(
                    inUse == 1 ? '1 application' : '$inUse applications',
                    style: theme.textTheme.labelSmall,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: stage.colorValue == null
                            ? 'Set colour'
                            : 'Change colour',
                        iconSize: 15,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _recolor(context, ref, stage),
                        icon: const Icon(PhosphorIconsRegular.palette),
                      ),
                      IconButton(
                        tooltip: 'Rename',
                        iconSize: 15,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _rename(context, stage),
                        icon: const Icon(PhosphorIconsRegular.pencilSimple),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        iconSize: 15,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _delete(context, stage, inUse),
                        icon: Icon(
                          PhosphorIconsRegular.trash,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            dense: true,
            icon: const Icon(PhosphorIconsRegular.plus),
            label: 'New stage',
            onPressed: () => _add(context),
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context) async {
    final name = await showPromptNameDialog(context, title: 'New stage');
    if (name == null) return;
    await actions.addStage(name);
  }

  Future<void> _rename(BuildContext context, JobStage stage) async {
    final name = await showPromptNameDialog(
      context,
      title: 'Rename stage',
      initial: stage.name,
    );
    if (name == null) return;
    await actions.renameStage(stage, name);
  }

  /// Colours the stage from the app palette. Unlike categories, other stages'
  /// colours are not passed as `usedColors`: two stages sharing a colour is
  /// the user's business, and the derived colours the uncoloured ones are
  /// showing are not choices anyone made.
  Future<void> _recolor(
    BuildContext context,
    WidgetRef ref,
    JobStage stage,
  ) async {
    final color = await pickPaletteColorWithRef(
      ref,
      context,
      current: stage.colorValue,
    );
    if (color == null) return;
    await actions.setStageColor(stage, color);
  }

  Future<void> _delete(BuildContext context, JobStage stage, int inUse) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${stage.name}"?',
      message: inUse == 0
          ? 'No applications are on this stage.'
          : '$inUse application${inUse == 1 ? '' : 's'} will keep '
                '"${stage.name}" as their status and show as an orphan stage. '
                'Their history is not changed.',
    );
    if (!confirmed) return;
    await actions.deleteStage(stage);
  }
}

/// The colour a stage's capsules are drawn in. A stage still on its
/// position-derived colour is drawn as an outline rather than a filled dot, so
/// "never chosen" reads differently from "chosen, and happens to be this".
class _StageSwatch extends StatelessWidget {
  const _StageSwatch({
    required this.color,
    required this.explicit,
    required this.onTap,
  });

  final Color color;
  final bool explicit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: explicit ? 'Change colour' : 'Set colour',
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: explicit ? color : color.withValues(alpha: 0.18),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: explicit ? 0 : 1.4),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

class _CategoriesTab extends ConsumerStatefulWidget {
  const _CategoriesTab({required this.actions});

  final JobsActions actions;

  @override
  ConsumerState<_CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends ConsumerState<_CategoriesTab> {
  String? _expandedCategoryId;
  final _companyFilterController = TextEditingController();

  @override
  void dispose() {
    _companyFilterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = ref.watch(jobCategoriesProvider).valueOrNull;
    final companies =
        ref.watch(jobCompaniesProvider).valueOrNull ?? const <JobCompany>[];
    if (categories == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final countByCategory = <String, int>{};
    for (final company in companies) {
      if (company.categoryId == null) continue;
      countByCategory[company.categoryId!] =
          (countByCategory[company.categoryId!] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'A company belongs to at most one category. Its colour is what the '
          'table shows beside every application for that company.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: categories.isEmpty
              ? Center(
                  child: Text(
                    'No categories yet',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ScrollOffsetIsolate(
                  child: VoyagerScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final category in categories)
                          _CategoryTile(
                            category: category,
                            companyCount: countByCategory[category.id] ?? 0,
                            expanded: _expandedCategoryId == category.id,
                            companies: companies,
                            filterController: _companyFilterController,
                            onToggleExpanded: () => setState(() {
                              _expandedCategoryId =
                                  _expandedCategoryId == category.id
                                  ? null
                                  : category.id;
                              _companyFilterController.clear();
                            }),
                            onRename: () => _rename(category),
                            onRecolor: () => _recolor(category, categories),
                            onDelete: () => _delete(category),
                            onToggleCompany: (company) {
                              widget.actions.setCompanyCategory(
                                company,
                                company.categoryId == category.id
                                    ? null
                                    : category.id,
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            dense: true,
            icon: const Icon(PhosphorIconsRegular.plus),
            label: 'New category',
            onPressed: () => _add(categories),
          ),
        ),
      ],
    );
  }

  Future<void> _add(List<JobCategory> categories) async {
    final palette = ref.read(colorPaletteProvider);
    final assigner = paletteFromItems(
      categories.map((category) => category.colorValue),
      palette,
    );
    final result = await showCreateNameColorDialog(
      context,
      title: 'New category',
      palette: palette,
      initialColor: assigner.nextColor(),
      usedColors: {for (final category in categories) category.colorValue},
    );
    if (result == null) return;
    await widget.actions.addCategory(result.name, result.color);
  }

  Future<void> _rename(JobCategory category) async {
    final name = await showPromptNameDialog(
      context,
      title: 'Rename category',
      initial: category.name,
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.actions.updateCategory(category, name: name.trim());
  }

  Future<void> _recolor(
    JobCategory category,
    List<JobCategory> categories,
  ) async {
    final color = await pickPaletteColorWithRef(
      ref,
      context,
      current: category.colorValue,
      usedColors: {
        for (final other in categories)
          if (other.id != category.id) other.colorValue,
      },
    );
    if (color == null) return;
    await widget.actions.updateCategory(category, colorValue: color);
  }

  Future<void> _delete(JobCategory category) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${category.name}"?',
      message:
          'Companies in this category become uncategorised and show the '
          'neutral colour. No applications are changed.',
    );
    if (!confirmed) return;
    await widget.actions.deleteCategory(category);
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.companyCount,
    required this.expanded,
    required this.companies,
    required this.filterController,
    required this.onToggleExpanded,
    required this.onRename,
    required this.onRecolor,
    required this.onDelete,
    required this.onToggleCompany,
  });

  final JobCategory category;
  final int companyCount;
  final bool expanded;
  final List<JobCompany> companies;
  final TextEditingController filterController;
  final VoidCallback onToggleExpanded;
  final VoidCallback onRename;
  final VoidCallback onRecolor;
  final VoidCallback onDelete;
  final ValueChanged<JobCompany> onToggleCompany;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          onTap: onToggleExpanded,
          leading: GestureDetector(
            onTap: onRecolor,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Color(category.colorValue),
                shape: BoxShape.circle,
              ),
            ),
          ),
          title: Text(category.name, style: theme.textTheme.bodySmall),
          subtitle: Text(
            companyCount == 1 ? '1 company' : '$companyCount companies',
            style: theme.textTheme.labelSmall,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Rename',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                onPressed: onRename,
                icon: const Icon(PhosphorIconsRegular.pencilSimple),
              ),
              IconButton(
                tooltip: 'Delete',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                onPressed: onDelete,
                icon: Icon(
                  PhosphorIconsRegular.trash,
                  color: theme.colorScheme.error,
                ),
              ),
              Icon(
                expanded
                    ? PhosphorIconsRegular.caretUp
                    : PhosphorIconsRegular.caretDown,
                size: 14,
              ),
            ],
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _CompanyAssignment(
              category: category,
              companies: companies,
              filterController: filterController,
              onToggleCompany: onToggleCompany,
            ),
          ),
      ],
    );
  }
}

class _CompanyAssignment extends StatefulWidget {
  const _CompanyAssignment({
    required this.category,
    required this.companies,
    required this.filterController,
    required this.onToggleCompany,
  });

  final JobCategory category;
  final List<JobCompany> companies;
  final TextEditingController filterController;
  final ValueChanged<JobCompany> onToggleCompany;

  @override
  State<_CompanyAssignment> createState() => _CompanyAssignmentState();
}

class _CompanyAssignmentState extends State<_CompanyAssignment> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Filtered rather than listed in full: the seed list alone is well over a
    // hundred companies, and scrolling that inside a dialog to find one is not
    // a way to assign a category.
    final query = widget.filterController.text;
    final matches = query.trim().isEmpty
        ? [
            for (final company in widget.companies)
              if (company.categoryId == widget.category.id) company,
          ]
        : filterJobCompanies(widget.companies, query).take(20).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Not under [VimTextScope] like the app's prose fields, so the Caps
        // Lock mark is opted into by hand here.
        CapsLockCaretIndicator(
          child: TextField(
            controller: widget.filterController,
            onChanged: (_) => setState(() {}),
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search companies to add…',
              prefixIcon: const Icon(
                PhosphorIconsRegular.magnifyingGlass,
                size: 14,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 30),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              query.trim().isEmpty
                  ? 'No companies in this category yet — search to add one.'
                  : 'No matches',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            // Mounted when a category is expanded, into a route whose one
            // page-storage slot every other list here also writes — see
            // [ScrollOffsetIsolate].
            child: ScrollOffsetIsolate(
              child: VoyagerScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final company in matches)
                      _CompanyRow(
                        company: company,
                        category: widget.category,
                        onTap: () => widget.onToggleCompany(company),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CompanyRow extends StatelessWidget {
  const _CompanyRow({
    required this.company,
    required this.category,
    required this.onTap,
  });

  final JobCompany company;
  final JobCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inThis = company.categoryId == category.id;
    // A company already filed elsewhere can only be moved, not added: one
    // category per company (§4.5), so tapping here takes it from the other one.
    final inOther = company.categoryId != null && !inThis;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            Icon(
              inThis
                  ? PhosphorIconsRegular.checkSquare
                  : PhosphorIconsRegular.square,
              size: 14,
              color: inThis
                  ? Color(category.colorValue)
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                company.name,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (inOther)
              Text(
                'in another category',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seasons
// ---------------------------------------------------------------------------

class _SeasonsTab extends ConsumerWidget {
  const _SeasonsTab({required this.actions});

  final JobsActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final seasons = ref.watch(jobSeasonsProvider).valueOrNull;
    final applications =
        ref.watch(jobApplicationsProvider).valueOrNull ??
        const <JobApplication>[];
    if (seasons == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // An application filed under several cycles counts once in each of them,
    // so the totals here add up to more than the table's row count — each one
    // answers "how much is in this season", which is what the row is asking.
    final countBySeason = <String, int>{};
    for (final application in applications) {
      for (final seasonId in application.seasonIds) {
        countBySeason[seasonId] = (countBySeason[seasonId] ?? 0) + 1;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Drag to reorder. A season is picked while tracking an application, '
          'and this order is the order the picker offers. Archive one when the '
          'cycle ends: everything in it leaves the default list at once, and '
          'the season stops being offered for anything new.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: seasons.isEmpty
              ? Center(
                  child: Text(
                    'No seasons yet',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ScrollOffsetIsolate(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: seasons.length,
                    // onReorderItem, not onReorder: it already adjusts newIndex
                    // for the item removed at oldIndex, so no off-by-one
                    // correction here.
                    onReorderItem: (oldIndex, newIndex) {
                      final ids = [for (final season in seasons) season.id];
                      ids.insert(newIndex, ids.removeAt(oldIndex));
                      actions.reorderSeasons(ids);
                    },
                    itemBuilder: (context, index) {
                      final season = seasons[index];
                      final count = countBySeason[season.id] ?? 0;
                      return ListTile(
                        key: ValueKey(season.id),
                        dense: true,
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(
                            PhosphorIconsRegular.dotsSixVertical,
                            size: 16,
                          ),
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                season.name,
                                style: theme.textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (season.isArchived) ...[
                              const SizedBox(width: 6),
                              Icon(
                                PhosphorIconsRegular.archive,
                                size: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          [
                            switch (count) {
                              0 => 'empty',
                              1 => '1 application',
                              final n => '$n applications',
                            },
                            if (season.isArchived) 'archived',
                          ].join(' — '),
                          style: theme.textTheme.labelSmall,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: season.isArchived
                                  ? 'Unarchive'
                                  : 'Archive season',
                              iconSize: 15,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => actions.setSeasonArchived(
                                season,
                                !season.isArchived,
                              ),
                              icon: Icon(
                                season.isArchived
                                    ? PhosphorIconsRegular.arrowCounterClockwise
                                    : PhosphorIconsRegular.archive,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Rename',
                              iconSize: 15,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _rename(context, season),
                              icon: const Icon(
                                PhosphorIconsRegular.pencilSimple,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              iconSize: 15,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _delete(context, season, count),
                              icon: Icon(
                                PhosphorIconsRegular.trash,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            dense: true,
            icon: const Icon(PhosphorIconsRegular.plus),
            label: 'New season',
            onPressed: () => _add(context),
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context) async {
    final name = await showPromptNameDialog(
      context,
      title: 'New season',
      label: 'Name (e.g. Fall 2025)',
    );
    if (name == null) return;
    await actions.addSeason(name);
  }

  Future<void> _rename(BuildContext context, JobSeason season) async {
    final name = await showPromptNameDialog(
      context,
      title: 'Rename season',
      initial: season.name,
    );
    if (name == null) return;
    await actions.renameSeason(season, name);
  }

  Future<void> _delete(
    BuildContext context,
    JobSeason season,
    int count,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${season.name}"?',
      message: count == 0
          ? 'This season is empty.'
          : '$count application${count == 1 ? '' : 's'} will be filed under no '
                'season and return to the active list. Nothing is deleted.',
    );
    if (!confirmed) return;
    await actions.deleteSeason(season);
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/caps_lock/caps_lock_caret_indicator.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/jobs_edit_panel.dart';
import 'package:voyager/features/jobs/jobs_header.dart';
import 'package:voyager/features/jobs/jobs_manage_sheet.dart';
import 'package:voyager/features/jobs/jobs_providers.dart';
import 'package:voyager/features/jobs/jobs_table.dart';

class JobsPage extends ConsumerStatefulWidget {
  const JobsPage({super.key});

  @override
  ConsumerState<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends ConsumerState<JobsPage>
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
    ref.read(jobSelectedApplicationProvider.notifier).state = id;
    _panelController.forward();
  }

  void _closePanel() {
    _panelController.reverse().then((_) {
      if (!mounted) return;
      ref.read(jobSelectedApplicationProvider.notifier).state = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final applicationsAsync = ref.watch(jobApplicationsProvider);
    final stages =
        ref.watch(jobStagesProvider).valueOrNull ?? const <JobStage>[];
    final companies =
        ref.watch(jobCompaniesProvider).valueOrNull ?? const <JobCompany>[];
    final categories =
        ref.watch(jobCategoriesProvider).valueOrNull ?? const <JobCategory>[];
    final seasons =
        ref.watch(jobSeasonsProvider).valueOrNull ?? const <JobSeason>[];
    final settings = ref.watch(settingsProvider).valueOrNull;

    final includeArchived = settings?.jobsIncludeArchived ?? false;
    final hiddenColumns =
        settings?.jobsHiddenColumns.toSet() ?? const <String>{};
    final columns = [
      for (final column in JobColumn.values)
        if (!hiddenColumns.contains(column.id)) column,
    ];
    final query = ref.watch(jobSearchQueryProvider);
    final statusFilter = ref.watch(jobStatusFilterProvider);
    final selectedId = ref.watch(jobSelectedApplicationProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: GlassButton(
        tooltip: 'Add an application',
        label: 'Add',
        icon: const Icon(PhosphorIconsRegular.plus),
        onPressed: () => _createApplication(companies),
      ),
      body: SafeArea(
        child: applicationsAsync.when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('$error')),
          data: (applications) {
            final colors = _CompanyColors(
              companies: companies,
              categories: categories,
              fallback: Theme.of(context).colorScheme.outline,
            );
            final statusColors = _StatusColors(
              stages: stages,
              fallback: Theme.of(context).colorScheme.primary,
            );

            final active = [
              for (final application in applications)
                if (!application.isArchived) application,
            ];
            // Three different scopes, deliberately (§8.1–§8.4). The lifetime
            // total counts everything ever. The per-status counts are always
            // active-only, whatever the toggle says. Only the sparkline and the
            // Sankey follow the toggle.
            final inScope = includeArchived ? applications : active;
            final rows = filterJobApplications(
              applications,
              includeArchived: includeArchived,
              statuses: statusFilter,
              query: query,
            )..sort((a, b) => b.dateApplied.compareTo(a.dateApplied));
            final duplicates = jobDuplicateIds(rows);
            final seasonNames = {
              for (final season in seasons) season.id: season.name,
            };
            final selected = selectedId == null
                ? null
                : applications.cast<JobApplication?>().firstWhere(
                    (application) => application!.id == selectedId,
                    orElse: () => null,
                  );

            return Column(
              children: [
                JobsHeader(
                  lifetimeTotal: applications.length,
                  statusCounts: jobStatusCounts(stages, active),
                  sankeyCounts: jobStatusCounts(stages, inScope),
                  dailyCounts: [
                    for (final day in jobDailyCounts(
                      inScope,
                      now: DateTime.now(),
                    ))
                      day.count,
                  ],
                  stages: stages,
                  includeArchived: includeArchived,
                  onIncludeArchivedChanged: (value) =>
                      _saveIncludeArchived(settings, value),
                  activeStatuses: statusFilter,
                  onStatusTapped: _toggleStatusFilter,
                  statusColors: statusColors.of,
                ),
                _Toolbar(
                  searchController: _searchController,
                  onQueryChanged: (value) =>
                      ref.read(jobSearchQueryProvider.notifier).state = value,
                  statusFilter: statusFilter,
                  onClearFilters: statusFilter.isEmpty && query.isEmpty
                      ? null
                      : _clearFilters,
                  hiddenColumns: hiddenColumns,
                  onToggleColumn: (column) =>
                      _toggleColumn(settings, hiddenColumns, column),
                  onManage: () => showJobsManageSheet(context, ref),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      AnimatedBuilder(
                        animation: _panelAnimation,
                        builder: (context, child) => Padding(
                          // The list gives up exactly as much width as the
                          // panel has taken, so the two never overlap while
                          // the reveal is mid-flight.
                          padding: EdgeInsets.only(
                            right: jobsEditPanelWidth * _panelAnimation.value,
                          ),
                          child: child,
                        ),
                        child: rows.isEmpty
                            ? _EmptyState(
                                hasApplications: applications.isNotEmpty,
                                onClearFilters: _clearFilters,
                              )
                            : Column(
                                children: [
                                  JobsTableHeader(columns: columns),
                                  Expanded(
                                    child: ListView.builder(
                                      itemCount: rows.length,
                                      itemBuilder: (context, index) {
                                        final application = rows[index];
                                        return JobsTableRow(
                                          key: ValueKey(application.id),
                                          application: application,
                                          columns: columns,
                                          color: colors.of(application.company),
                                          isDuplicate: duplicates.contains(
                                            application.id,
                                          ),
                                          isSelected:
                                              application.id == selectedId,
                                          seasonName:
                                              seasonNames[application.seasonId],
                                          onTap: () =>
                                              _openPanel(application.id),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        child: ClipRect(
                          child: AnimatedBuilder(
                            animation: _panelAnimation,
                            builder: (context, child) => Align(
                              alignment: Alignment.centerRight,
                              widthFactor: _panelAnimation.value,
                              child: child,
                            ),
                            child: SizedBox(
                              width: jobsEditPanelWidth,
                              child: selected == null
                                  ? const SizedBox.shrink()
                                  : JobsEditPanel(
                                      key: ValueKey(selected.id),
                                      application: selected,
                                      stages: stages,
                                      companies: companies,
                                      seasons: seasons,
                                      accentColor: colors.of(selected.company),
                                      categoryColorFor: colors.forCompany,
                                      onClose: _closePanel,
                                      onDeleted: _closePanel,
                                      onDuplicated: (copy) =>
                                          _openPanel(copy.id),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _createApplication(List<JobCompany> companies) async {
    final company = await showPromptNameDialog(
      context,
      title: 'New application',
      label: 'Company',
    );
    if (company == null || company.trim().isEmpty || !mounted) return;
    final title = await showPromptNameDialog(
      context,
      title: 'New application',
      label: 'Title',
    );
    if (title == null || title.trim().isEmpty) return;
    final created = await JobsActions(
      ref,
    ).createApplication(company: company, title: title);
    if (!mounted) return;
    // Opened straight away: company and title are the only fields create asks
    // for, and everything else — status, date, URL, notes — is edited here.
    _openPanel(created.id);
  }

  void _toggleStatusFilter(String status) {
    final notifier = ref.read(jobStatusFilterProvider.notifier);
    final next = {...notifier.state};
    if (!next.remove(status)) next.add(status);
    notifier.state = next;
  }

  void _clearFilters() {
    _searchController.clear();
    ref.read(jobSearchQueryProvider.notifier).state = '';
    ref.read(jobStatusFilterProvider.notifier).state = const {};
  }

  Future<void> _saveIncludeArchived(AppSettings? settings, bool value) async {
    if (settings == null) return;
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(settings.copyWith(jobsIncludeArchived: value));
  }

  Future<void> _toggleColumn(
    AppSettings? settings,
    Set<String> hidden,
    JobColumn column,
  ) async {
    if (settings == null || jobRequiredColumns.contains(column)) return;
    final next = {...hidden};
    if (!next.remove(column.id)) next.add(column.id);
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(settings.copyWith(jobsHiddenColumns: next.toList()));
  }
}

/// Resolves an application's `company` string to the colour of the category
/// its suggestion-list entry is filed under (§4.5).
///
/// Matching is on the case-folded name rather than an id, because an
/// application stores the company as free text and may name a company that was
/// since removed from the suggestion list.
class _CompanyColors {
  _CompanyColors({
    required List<JobCompany> companies,
    required List<JobCategory> categories,
    required this.fallback,
  }) : _categoryById = {
         for (final category in categories) category.id: category,
       },
       _companyByKey = {
         for (final company in companies) jobCompanyKey(company.name): company,
       };

  final Color fallback;
  final Map<String, JobCategory> _categoryById;
  final Map<String, JobCompany> _companyByKey;

  Color of(String companyName) {
    final company = _companyByKey[jobCompanyKey(companyName)];
    return forCompany(company) ?? fallback;
  }

  Color? forCompany(JobCompany? company) {
    final categoryId = company?.categoryId;
    if (categoryId == null) return null;
    final category = _categoryById[categoryId];
    return category == null ? null : Color(category.colorValue);
  }
}

/// A stable colour per status, spread around the theme's hue wheel by the
/// stage's position. Orphan statuses (not in the stage list) all share the
/// muted outline colour, which is what marks them apart at a glance.
class _StatusColors {
  _StatusColors({required List<JobStage> stages, required this.fallback})
    : _indexByName = {
        for (var i = 0; i < stages.length; i++) stages[i].name: i,
      },
      _count = stages.length;

  final Color fallback;
  final Map<String, int> _indexByName;
  final int _count;

  Color of(String status) {
    final index = _indexByName[status];
    if (index == null || _count == 0) return fallback;
    final hsl = HSLColor.fromColor(fallback);
    return hsl.withHue((hsl.hue + (360 / _count) * index) % 360).toColor();
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.searchController,
    required this.onQueryChanged,
    required this.statusFilter,
    required this.onClearFilters,
    required this.hiddenColumns,
    required this.onToggleColumn,
    required this.onManage,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onQueryChanged;
  final Set<String> statusFilter;
  final VoidCallback? onClearFilters;
  final Set<String> hiddenColumns;
  final ValueChanged<JobColumn> onToggleColumn;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 32,
              // Not under [VimTextScope] like the app's prose fields, so the
              // Caps Lock mark is opted into by hand here.
              child: CapsLockCaretIndicator(
                child: TextField(
                  controller: searchController,
                  onChanged: onQueryChanged,
                  style: theme.textTheme.bodySmall,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search company, title, notes or status',
                    prefixIcon: const Icon(
                      PhosphorIconsRegular.magnifyingGlass,
                      size: 14,
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ),
          ),
          if (onClearFilters != null) ...[
            const SizedBox(width: 6),
            TextButton(
              onPressed: onClearFilters,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: const Text('Clear'),
            ),
          ],
          const SizedBox(width: 6),
          Builder(
            builder: (buttonContext) => IconButton(
              tooltip: 'Columns',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () => showContextualPopover<void>(
                context: context,
                buttonContext: buttonContext,
                builder: (context) => _ColumnMenu(
                  hiddenColumns: hiddenColumns,
                  onToggle: onToggleColumn,
                ),
              ),
              icon: const Icon(PhosphorIconsRegular.columns),
            ),
          ),
          IconButton(
            tooltip: 'Manage stages, categories and seasons',
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

class _ColumnMenu extends StatefulWidget {
  const _ColumnMenu({required this.hiddenColumns, required this.onToggle});

  final Set<String> hiddenColumns;
  final ValueChanged<JobColumn> onToggle;

  @override
  State<_ColumnMenu> createState() => _ColumnMenuState();
}

class _ColumnMenuState extends State<_ColumnMenu> {
  late final Set<String> _hidden = {...widget.hiddenColumns};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final column in JobColumn.values)
          InkWell(
            // Company and title cannot be switched off — without them a row
            // has nothing to identify it by.
            onTap: jobRequiredColumns.contains(column)
                ? null
                : () {
                    widget.onToggle(column);
                    setState(() {
                      if (!_hidden.remove(column.id)) _hidden.add(column.id);
                    });
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _hidden.contains(column.id)
                        ? PhosphorIconsRegular.square
                        : PhosphorIconsRegular.checkSquare,
                    size: 14,
                    color: jobRequiredColumns.contains(column)
                        ? theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.4,
                          )
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(column.label, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.hasApplications,
    required this.onClearFilters,
  });

  /// True when the table is empty only because of the filters, which is a
  /// different message — and a different remedy — from having nothing tracked.
  final bool hasApplications;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            hasApplications
                ? 'No applications match these filters'
                : 'No applications tracked yet',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (hasApplications) ...[
            const SizedBox(height: 8),
            GlassButton(
              dense: true,
              label: 'Clear filters',
              onPressed: onClearFilters,
            ),
          ],
        ],
      ),
    );
  }
}

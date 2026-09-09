import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/caps_lock/caps_lock_caret_indicator.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/jobs_edit_panel.dart';
import 'package:voyager/features/jobs/jobs_header.dart';
import 'package:voyager/features/jobs/jobs_manage_sheet.dart';
import 'package:voyager/features/jobs/jobs_option_list.dart';
import 'package:voyager/features/jobs/jobs_providers.dart';
import 'package:voyager/features/jobs/jobs_stage_colors.dart';
import 'package:voyager/features/jobs/jobs_table.dart';
import 'package:voyager/features/jobs/jobs_track_modal.dart';

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
        onPressed: _createApplication,
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
            final statusColors = JobStageColors(
              stages: stages,
              fallback: Theme.of(context).colorScheme.primary,
            );

            // Archived-ness lives on the seasons, not on the application: a
            // season is picked while tracking, and an application is archived
            // only once every cycle it is filed under has been retired.
            final archivedSeasonIds = jobArchivedSeasonIds(seasons);
            final active = [
              for (final application in applications)
                if (!jobIsArchived(application, archivedSeasonIds)) application,
            ];
            // Three different scopes, deliberately (§8.1–§8.3). The lifetime
            // total counts everything ever. The per-status counts are always
            // active-only, whatever the toggle says. Only the list and the
            // sparkline follow the toggle.
            final inScope = includeArchived ? applications : active;
            final rows = filterJobApplications(
              applications,
              includeArchived: includeArchived,
              archivedSeasonIds: archivedSeasonIds,
              statuses: statusFilter,
              query: query,
            )..sort(compareJobApplications);
            final duplicates = jobDuplicateIds(rows);
            // Named in the user's own season order rather than in the order
            // the ids happen to sit in on the application, so two rows in the
            // same pair of cycles read identically.
            List<String> namesFor(JobApplication application) => [
              for (final season in seasons)
                if (application.seasonIds.contains(season.id)) season.name,
            ];
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
                  profileLinkedInUrl: settings?.jobProfileLinkedInUrl,
                  profileGitHubUrl: settings?.jobProfileGitHubUrl,
                  profilePortfolioUrl: settings?.jobProfilePortfolioUrl,
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
                                          statusColor: statusColors.of(
                                            application.status,
                                          ),
                                          isDuplicate: duplicates.contains(
                                            application.id,
                                          ),
                                          isSelected:
                                              application.id == selectedId,
                                          isArchived: jobIsArchived(
                                            application,
                                            archivedSeasonIds,
                                          ),
                                          seasonNames: namesFor(application),
                                          onTap: () =>
                                              _openPanel(application.id),
                                          onStatusTap: (pillContext) =>
                                              _editStatus(
                                                pillContext,
                                                application,
                                                stages,
                                              ),
                                          menuItems: () =>
                                              jobApplicationMenuItems(
                                                application: application,
                                                stages: stages,
                                                seasons: jobSelectableSeasons(
                                                  seasons,
                                                ),
                                                onChangeStatus: (status) =>
                                                    _setStatus(
                                                      application,
                                                      status,
                                                    ),
                                                onSetSeasons: (seasonIds) =>
                                                    _setSeasons(
                                                      application,
                                                      seasonIds,
                                                    ),
                                                onOpenUrl: () => _openUrl(
                                                  application.applicationUrl!,
                                                ),
                                                onDuplicate: () =>
                                                    _duplicate(application),
                                                onDelete: () =>
                                                    _confirmDelete(application),
                                              ),
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
                                      recentCompanyKeys: jobRecentCompanyKeys(
                                        applications,
                                      ),
                                      accentColor: colors.of(selected.company),
                                      categoryColorFor: colors.forCompany,
                                      onClose: _closePanel,
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

  /// One page collects the whole application — company, role, stage, date,
  /// season, URL and notes — and nothing is written until it is saved. The
  /// panel is deliberately not opened afterwards: there is nothing left to
  /// fill in.
  Future<void> _createApplication() async {
    await startJobsTrackFlow(context, ref);
  }

  /// Applies a status picked from the row's capsule or its right-click menu.
  /// The same write the editor panel makes, so it records the timeline entry
  /// too.
  Future<void> _setStatus(JobApplication application, String status) async {
    if (status == application.status) return;
    await JobsActions(ref).saveApplication(
      application.copyWith(status: status),
      previous: application,
    );
  }

  Future<void> _editStatus(
    BuildContext pillContext,
    JobApplication application,
    List<JobStage> stages,
  ) async {
    // Orphans included: a status whose stage was deleted still has to be
    // selectable back onto itself, and visible as an option so the user can
    // see what the application is actually on.
    final names = [
      for (final stage in stages) stage.name,
      if (application.status.isNotEmpty &&
          !stages.any((s) => s.name == application.status))
        application.status,
    ];
    final picked = await showContextualPopover<String>(
      context: context,
      buttonContext: pillContext,
      builder: (context) => JobsOptionList(
        options: [for (final name in names) (value: name, label: name)],
        selected: application.status,
      ),
    );
    if (picked == null) return;
    await _setStatus(application, picked);
  }

  /// Copies the application and opens the copy. Lives on the row's right-click
  /// menu rather than in the editor panel — the panel is for editing the one
  /// application it is showing, not for minting another.
  Future<void> _duplicate(JobApplication application) async {
    final copy = await JobsActions(ref).duplicateApplication(application);
    _openPanel(copy.id);
  }

  Future<void> _setSeasons(
    JobApplication application,
    Set<String> seasonIds,
  ) async {
    if (setEquals(seasonIds, application.seasonIds.toSet())) return;
    await JobsActions(ref).setSeasons(application, seasonIds.toList());
  }

  Future<void> _confirmDelete(JobApplication application) async {
    // Captured while this widget is still mounted: the delete unmounts the row
    // that asked for it, and the toast offering the undo has to outlive both.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete application?',
      message:
          '${application.title} at ${application.company} and its status '
          'history will be moved to trash.',
    );
    if (!confirmed) return;
    // The panel would otherwise be left showing a tombstone, and its dispose
    // flush would write the content straight back.
    if (ref.read(jobSelectedApplicationProvider) == application.id) {
      _closePanel();
    }

    final actions = JobsActions.detached(container);
    late final JobApplicationSnapshot snapshot;
    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(
        '${application.title} at ${application.company}',
        fallback: 'application',
      ),
      delete: () async => snapshot = await actions.deleteApplication(application),
      // Reopened whether or not it was the application on screen when it went:
      // the undo is about that one row, and the editor is where it lives.
      restore: () async {
        await actions.restoreApplication(snapshot);
        if (!mounted) return;
        // The panel resolves its application out of [jobApplicationsProvider],
        // which the restore has just invalidated. Opening before it has the
        // row back slides an empty panel out and fills it a frame or two
        // later; waiting means it opens on the application straight away.
        await ref.read(jobApplicationsProvider.future);
        if (!mounted) return;
        _openPanel(application.id);
      },
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
              height: 38,
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
            GlassButton(
              dense: true,
              height: 38,
              label: 'Clear',
              onPressed: onClearFilters,
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

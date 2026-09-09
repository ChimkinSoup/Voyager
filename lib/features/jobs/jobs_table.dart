import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_providers.dart';

/// Relative widths of the flat table's columns (§3.2). Color is a fixed-width
/// swatch gutter; the rest share the remaining space by flex.
const _columnFlex = <JobColumn, int>{
  JobColumn.company: 2,
  JobColumn.title: 5,
  JobColumn.status: 2,
  JobColumn.dateApplied: 2,
  JobColumn.season: 2,
  JobColumn.notes: 4,
};

const _colorColumnWidth = 22.0;
const _warningColumnWidth = 22.0;

class JobsTableHeader extends StatelessWidget {
  const JobsTableHeader({super.key, required this.columns});

  final List<JobColumn> columns;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          // Always reserved, whether or not the color column is on: the
          // duplicate marker lives here too, and a gutter that appears and
          // disappears would shift every column when a duplicate shows up.
          const SizedBox(width: _warningColumnWidth),
          if (columns.contains(JobColumn.color))
            const SizedBox(width: _colorColumnWidth),
          for (final column in columns)
            if (column != JobColumn.color)
              Expanded(
                flex: _columnFlex[column]!,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(column.label, style: style),
                ),
              ),
          const SizedBox(width: 28),
        ],
      ),
    );
  }
}

/// The right-click menu for one application row.
///
/// Built by the page, which is the only place that knows the stage and season
/// lists these submenus offer. "Open application URL" is absent rather than
/// disabled when there is no URL — an entry that can never do anything is
/// noise, not information.
List<ContextMenuItem> jobApplicationMenuItems({
  required JobApplication application,
  required List<JobStage> stages,
  required List<JobSeason> seasons,
  required ValueChanged<String> onChangeStatus,
  required ValueChanged<Set<String>> onSetSeasons,
  required VoidCallback onOpenUrl,
  required VoidCallback onDuplicate,
  required VoidCallback onDelete,
}) {
  final url = application.applicationUrl?.trim() ?? '';
  return [
    ContextMenuItem(
      label: 'Status',
      icon: PhosphorIconsRegular.flowArrow,
      children: [
        for (final stage in stages)
          ContextMenuItem(
            label: stage.name,
            trailing: stage.name == application.status
                ? const Icon(PhosphorIconsRegular.check, size: 13)
                : null,
            onTap: () => onChangeStatus(stage.name),
          ),
      ],
    ),
    // One membership per visit: the menu closes on a tap, so each entry
    // toggles the season it names and leaves the rest alone. Filing something
    // under several cycles at once is the editor panel's picker, which stays
    // open; this is the quick "also put it in Fall 2026".
    ContextMenuItem(
      label: 'Seasons',
      icon: PhosphorIconsRegular.calendarCheck,
      children: [
        ContextMenuItem(
          label: 'No season',
          trailing: application.seasonIds.isEmpty
              ? const Icon(PhosphorIconsRegular.check, size: 13)
              : null,
          onTap: () => onSetSeasons(const {}),
        ),
        for (final season in seasons)
          ContextMenuItem(
            label: season.name,
            trailing: application.seasonIds.contains(season.id)
                ? const Icon(PhosphorIconsRegular.check, size: 13)
                : null,
            onTap: () {
              final next = application.seasonIds.toSet();
              if (!next.remove(season.id)) next.add(season.id);
              onSetSeasons(next);
            },
          ),
      ],
    ),
    if (url.isNotEmpty)
      ContextMenuItem(
        label: 'Open application URL',
        icon: PhosphorIconsRegular.arrowSquareOut,
        onTap: onOpenUrl,
      ),
    ContextMenuItem(
      label: 'Duplicate',
      icon: PhosphorIconsRegular.copy,
      onTap: onDuplicate,
    ),
    ContextMenuItem(
      label: 'Delete',
      icon: PhosphorIconsRegular.trash,
      isDestructive: true,
      onTap: onDelete,
    ),
  ];
}

class JobsTableRow extends StatelessWidget {
  const JobsTableRow({
    super.key,
    required this.application,
    required this.columns,
    required this.color,
    required this.statusColor,
    required this.isDuplicate,
    required this.isSelected,
    required this.isArchived,
    required this.seasonNames,
    required this.onTap,
    required this.onStatusTap,
    required this.menuItems,
  });

  final JobApplication application;
  final List<JobColumn> columns;

  /// The category colour of the application's company, or the neutral default
  /// when the company is uncategorised or unrecognised (§4.5).
  final Color color;

  /// The colour of the application's *stage* — the stage's own colour when it
  /// has one, otherwise the position-derived one. Distinct from [color]: the
  /// swatch gutter says which company category a row belongs to, and the
  /// status capsule says where it is in the pipeline.
  final Color statusColor;

  /// Another row links to the same posting URL (§7.3). Informational only.
  final bool isDuplicate;
  final bool isSelected;

  /// Whether every season this application is filed under has been retired.
  /// Not a property of the application — see [jobIsArchived].
  final bool isArchived;

  /// The seasons the application is filed under, in the user's season order,
  /// so the row can say which ones (§6.3). Empty for none.
  final List<String> seasonNames;
  final VoidCallback onTap;

  /// Opens the stage picker anchored to the status capsule, whose own
  /// [BuildContext] is what the popover measures against. Editing the status
  /// in place is the whole point — no need to open the panel first.
  final ValueChanged<BuildContext> onStatusTap;

  /// Built on right-click rather than eagerly: the entries are only ever
  /// looked at when the menu opens, and a season submenu per row adds up.
  final ValueGetter<List<ContextMenuItem>> menuItems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ContextMenuRegion(
      itemsBuilder: menuItems,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            decoration: BoxDecoration(
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.08)
                  : null,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.3,
                  ),
                ),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: _warningColumnWidth,
                  child: isDuplicate
                      ? Tooltip(
                          message:
                              'Another application links to the same posting '
                              'URL',
                          child: Icon(
                            PhosphorIconsRegular.warningCircle,
                            size: 14,
                            color: theme.colorScheme.tertiary,
                          ),
                        )
                      : null,
                ),
                if (columns.contains(JobColumn.color))
                  SizedBox(
                    width: _colorColumnWidth,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                for (final column in columns)
                  if (column != JobColumn.color)
                    Expanded(
                      flex: _columnFlex[column]!,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _cell(context, column),
                      ),
                    ),
                SizedBox(
                  width: 28,
                  child: isArchived
                      ? Tooltip(
                          message: seasonNames.isEmpty
                              ? 'Archived'
                              : 'Archived — ${seasonNames.join(', ')}',
                          child: Icon(
                            PhosphorIconsRegular.archive,
                            size: 13,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, JobColumn column) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    switch (column) {
      case JobColumn.color:
        return const SizedBox.shrink();
      case JobColumn.company:
        return Text(
          application.company,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
        );
      case JobColumn.title:
        return Text(
          application.title,
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        );
      case JobColumn.status:
        return Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: 'Change status',
            waitDuration: const Duration(milliseconds: 500),
            // Nested inside the row's own InkWell: the innermost hit wins the
            // gesture arena, so tapping the capsule edits the status and
            // tapping anywhere else on the row still opens the panel.
            child: Builder(
              builder: (pillContext) => InkWell(
                onTap: () => onStatusTap(pillContext),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    application.status.isEmpty ? '—' : application.status,
                    style: theme.textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        );
      case JobColumn.dateApplied:
        return Text(
          DateFormat.yMMMd().format(application.dateApplied.toLocal()),
          style: muted,
          overflow: TextOverflow.ellipsis,
        );
      case JobColumn.season:
        // The names alone: whether a season is retired is already carried by
        // the archive marker at the end of the row, and repeating it here
        // would spend the column's width on saying it twice. Several are
        // joined rather than stacked so every row stays one line tall.
        return Text(
          seasonNames.isEmpty ? '—' : seasonNames.join(', '),
          style: muted,
          overflow: TextOverflow.ellipsis,
        );
      case JobColumn.notes:
        // A preview only — the full text (markdown, #tags and all) lives in the
        // editor panel. Newlines are folded so a multi-paragraph note cannot
        // make one row taller than the rest.
        final preview = (application.notes ?? '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return Text(
          preview,
          style: muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
  }
}

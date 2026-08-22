import 'package:flutter/material.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';

/// The always-visible compact header (§3.1): lifetime total, per-status counts,
/// a 30-day sparkline and the Sankey, in one row.
class JobsHeader extends StatelessWidget {
  const JobsHeader({
    super.key,
    required this.lifetimeTotal,
    required this.statusCounts,
    required this.sankeyCounts,
    required this.dailyCounts,
    required this.stages,
    required this.includeArchived,
    required this.onIncludeArchivedChanged,
    required this.activeStatuses,
    required this.onStatusTapped,
    required this.statusColors,
  });

  /// Every application ever, archived and tombstoned-excluded alike (§8.1).
  /// Unaffected by the include-archived toggle.
  final int lifetimeTotal;

  /// Per-status counts for the chips (§8.2): **active applications only**,
  /// whatever the include-archived toggle says. Already ordered by the user's
  /// stage order, with orphans last.
  ///
  /// A consequence worth knowing: with archived rows showing, a status carried
  /// only by archived applications has no chip to filter by. Searching for the
  /// status name still reaches those rows (§6.1).
  final List<({String status, int count})> statusCounts;

  /// The Sankey's own counts (§8.4), which unlike [statusCounts] do follow the
  /// include-archived toggle.
  final List<({String status, int count})> sankeyCounts;
  final List<int> dailyCounts;
  final List<JobStage> stages;
  final bool includeArchived;
  final ValueChanged<bool> onIncludeArchivedChanged;

  /// Statuses the table is currently filtered to, so the chips can double as
  /// the filter control (§6.2).
  final Set<String> activeStatuses;
  final ValueChanged<String> onStatusTapped;
  final Color Function(String status) statusColors;

  @override
  Widget build(BuildContext context) {
    final stageNames = {for (final stage in stages) stage.name};

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: SizedBox(
        height: 76,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LifetimeTotal(total: lifetimeTotal),
            const SizedBox(width: 18),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: _StatusChips(
                      statusCounts: statusCounts,
                      stageNames: stageNames,
                      activeStatuses: activeStatuses,
                      onStatusTapped: onStatusTapped,
                      statusColors: statusColors,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _IncludeArchivedToggle(
                    value: includeArchived,
                    onChanged: onIncludeArchivedChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 3,
              child: _LabelledChart(
                label: 'Last 30 days',
                child: JobsSparkline(counts: dailyCounts),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 2,
              child: _LabelledChart(
                label: 'Pipeline',
                child: JobsSankey(
                  flows: [
                    for (final entry in sankeyCounts)
                      (
                        status: entry.status,
                        count: entry.count,
                        color: statusColors(entry.status),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LifetimeTotal extends StatelessWidget {
  const _LifetimeTotal({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '$total',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          total == 1 ? 'application' : 'applications',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          'all time',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

class _StatusChips extends StatelessWidget {
  const _StatusChips({
    required this.statusCounts,
    required this.stageNames,
    required this.activeStatuses,
    required this.onStatusTapped,
    required this.statusColors,
  });

  final List<({String status, int count})> statusCounts;
  final Set<String> stageNames;
  final Set<String> activeStatuses;
  final ValueChanged<String> onStatusTapped;
  final Color Function(String status) statusColors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (statusCounts.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'No active applications',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in statusCounts) ...[
            _StatusChip(
              status: entry.status,
              count: entry.count,
              color: statusColors(entry.status),
              selected: activeStatuses.contains(entry.status),
              // A status no longer in the stage list is an orphan (§7.5). It
              // stays countable and filterable; the marker is the only thing
              // that says the stage behind it is gone.
              orphan: !stageNames.contains(entry.status),
              onTap: () => onStatusTapped(entry.status),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.status,
    required this.count,
    required this.color,
    required this.selected,
    required this.orphan,
    required this.onTap,
  });

  final String status;
  final int count;
  final Color color;
  final bool selected;
  final bool orphan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: orphan
          ? '$status — this stage no longer exists'
          : 'Filter by $status',
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
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  status.isEmpty ? 'No status' : status,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontStyle: orphan ? FontStyle.italic : null,
                  ),
                ),
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

class _IncludeArchivedToggle extends StatelessWidget {
  const _IncludeArchivedToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => onChanged(!value),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  value ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 14,
                  color: value
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  'Include archived',
                  style: theme.textTheme.labelSmall?.copyWith(
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

class _LabelledChart extends StatelessWidget {
  const _LabelledChart({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(child: child),
      ],
    );
  }
}

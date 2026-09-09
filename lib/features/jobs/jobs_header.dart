import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';

/// The always-visible compact header (§3.1): lifetime total, per-status counts
/// and a 30-day sparkline, in one row.
class JobsHeader extends StatelessWidget {
  const JobsHeader({
    super.key,
    required this.lifetimeTotal,
    required this.statusCounts,
    required this.dailyCounts,
    required this.stages,
    required this.includeArchived,
    required this.onIncludeArchivedChanged,
    required this.activeStatuses,
    required this.onStatusTapped,
    required this.statusColors,
    this.profileLinkedInUrl,
    this.profileGitHubUrl,
    this.profilePortfolioUrl,
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

  final List<int> dailyCounts;
  final List<JobStage> stages;
  final bool includeArchived;
  final ValueChanged<bool> onIncludeArchivedChanged;

  /// Statuses the table is currently filtered to, so the chips can double as
  /// the filter control (§6.2).
  final Set<String> activeStatuses;
  final ValueChanged<String> onStatusTapped;
  final Color Function(String status) statusColors;

  /// The user's own profile links (§3.4), straight from settings. Each
  /// non-empty one gets a copy button; with all three unset the whole group
  /// disappears, its spacing included.
  final String? profileLinkedInUrl;
  final String? profileGitHubUrl;
  final String? profilePortfolioUrl;

  @override
  Widget build(BuildContext context) {
    final stageNames = {for (final stage in stages) stage.name};
    final profileLinks = [
      if ((profileLinkedInUrl ?? '').isNotEmpty)
        (
          label: 'LinkedIn',
          icon: PhosphorIconsRegular.linkedinLogo,
          url: profileLinkedInUrl!,
        ),
      if ((profileGitHubUrl ?? '').isNotEmpty)
        (
          label: 'GitHub',
          icon: PhosphorIconsRegular.githubLogo,
          url: profileGitHubUrl!,
        ),
      if ((profilePortfolioUrl ?? '').isNotEmpty)
        (
          label: 'Portfolio',
          icon: PhosphorIconsRegular.globeHemisphereWest,
          url: profilePortfolioUrl!,
        ),
    ];

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
              flex: 5,
              // The chart caps itself at 260px and sits right-aligned, so the
              // slack in this half is to its left — which is exactly where the
              // copy buttons belong (§3.4). Sharing the half keeps them beside
              // the chart at any width instead of stranded mid-row.
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (profileLinks.isNotEmpty) ...[
                    _ProfileCopyButtons(links: profileLinks),
                    const SizedBox(width: 12),
                  ],
                  // Flexible so the chart gives ground first when the half
                  // is narrow. It caps itself at 260px and its Align keeps it
                  // right of whatever it is given, so it only ever shrinks —
                  // and the copy buttons, which cannot, stay whole.
                  Flexible(
                    child: _LabelledChart(
                      label: 'Last 30 days',
                      child: JobsSparkline(counts: dailyCounts),
                    ),
                  ),
                ],
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

/// One-tap clipboard copies of the user's own profile links (§3.4).
///
/// Icon-only: the header row is a fixed 76px and the chart beside it already
/// claims half the width, so labelled buttons would take their width off the
/// status chips. The tooltip carries the slot name instead.
class _ProfileCopyButtons extends StatelessWidget {
  const _ProfileCopyButtons({required this.links});

  final List<({String label, IconData icon, String url})> links;

  @override
  Widget build(BuildContext context) {
    // The header row stretches its children to its full 76px; centre the
    // buttons in that rather than letting them stand full height.
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final link in links)
            _ProfileCopyButton(
              label: link.label,
              icon: link.icon,
              url: link.url,
            ),
        ],
      ),
    );
  }
}

class _ProfileCopyButton extends StatelessWidget {
  const _ProfileCopyButton({
    required this.label,
    required this.icon,
    required this.url,
  });

  final String label;
  final IconData icon;
  final String url;

  Future<void> _copy(BuildContext context) async {
    // Read the overlay before the await: the header rebuilds on every settings
    // change, so this context may be gone once the copy resolves.
    final overlay = Overlay.of(context, rootOverlay: true);
    await Clipboard.setData(ClipboardData(text: url));
    showVoyagerToastIn(
      overlay,
      message: '$label copied',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Copy $label URL',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => _copy(context),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              icon,
              size: 24,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _LabelledChart extends StatelessWidget {
  const _LabelledChart({required this.label, required this.child});

  /// Thirty days spread across the header's full half stretch the line into a
  /// near-flat drift rather than a chart; capped, a day is ~8.7px and the
  /// day-to-day swings are steep enough to read.
  static const double _maxWidth = 260;

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: Column(
          // Stretch, not start: it hands both children *tight* cross-axis
          // constraints, which centres the label over the chart's real width
          // and keeps the chart — which sizes itself to its box rather than
          // to any content, so a loose width would collapse it — the full
          // capped width.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

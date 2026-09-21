import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/job_experience_snippet.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

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
    this.experienceSnippets = const [],
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

  /// The user's experience snippets, in Settings order. Each copies its
  /// description; the first few that fit are chips and the rest sit behind an
  /// overflow menu. Empty hides the group, spacing included.
  final List<JobExperienceSnippet> experienceSnippets;

  /// Between the profile icons, the experience chips and the chart.
  static const double _groupGap = 12;

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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Everything in this half but the chips has a known width,
                  // so what is left for them is settled before they lay out.
                  // The chart's floor comes off too: chips that would squeeze
                  // it below that move into the overflow menu instead.
                  final chipBudget =
                      constraints.maxWidth -
                      (profileLinks.isEmpty
                          ? 0
                          : profileLinks.length * _ProfileCopyButton.extent +
                                _groupGap) -
                      _groupGap -
                      _LabelledChart.minWidth;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (profileLinks.isNotEmpty) ...[
                        _ProfileCopyButtons(links: profileLinks),
                        const SizedBox(width: _groupGap),
                      ],
                      if (experienceSnippets.isNotEmpty) ...[
                        _ExperienceCopyButtons(
                          snippets: experienceSnippets,
                          budget: chipBudget,
                        ),
                        const SizedBox(width: _groupGap),
                      ],
                      // Flexible so the chart gives ground first when the
                      // half is narrow. It caps itself at 260px and takes no
                      // more than that, so it only ever shrinks — and the
                      // copy buttons, which cannot, stay whole.
                      Flexible(
                        child: _LabelledChart(
                          label: 'Last 30 days',
                          child: JobsSparkline(counts: dailyCounts),
                        ),
                      ),
                    ],
                  );
                },
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
          borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: selected
                  ? color.withValues(alpha: 0.20)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
              borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
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

  static const double _padding = 10;
  static const double _iconSize = 24;

  /// The button's width, which the header budgets the experience chips from.
  static const double extent = _padding * 2 + _iconSize;

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
            padding: const EdgeInsets.all(_padding),
            child: Icon(
              icon,
              size: _iconSize,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

const int _kMaxExperienceChips = 3;
const double _kExperienceChipMinWidth = 90;
const double _kExperienceChipMaxWidth = 160;
const double _kExperienceChipGap = 6;
const double _kExperienceOverflowWidth = 28;

/// How many experience chips fit in [budget], and the widest any may be.
///
/// [naturalWidths] are the untruncated widths of the leading chips, in the
/// user's order; [total] counts every snippet, so whatever is not shown can
/// reserve room for the overflow button. Chips fill from the front, up to
/// [maxVisible] — a chip fits if it can show at least [minChipWidth] of itself
/// (all of itself, when shorter). Among those that fit, space is shared
/// water-level style: short names keep their full width and only the longest
/// are truncated to the returned cap.
@visibleForTesting
({int visible, double maxChipWidth}) layoutExperienceChips({
  required List<double> naturalWidths,
  required int total,
  required double budget,
  int maxVisible = _kMaxExperienceChips,
  double minChipWidth = _kExperienceChipMinWidth,
  double maxChipWidth = _kExperienceChipMaxWidth,
  double gap = _kExperienceChipGap,
  double overflowWidth = _kExperienceOverflowWidth,
}) {
  for (var k = math.min(maxVisible, naturalWidths.length); k > 0; k--) {
    final widths = [
      for (final width in naturalWidths.take(k)) math.min(width, maxChipWidth),
    ];
    final space =
        budget - gap * (k - 1) - (k < total ? gap + overflowWidth : 0);
    final floor = widths.fold<double>(
      0,
      (sum, width) => sum + math.min(width, minChipWidth),
    );
    if (floor > space) continue;
    return (
      visible: k,
      maxChipWidth: _waterLevel(widths, space, maxChipWidth),
    );
  }
  return (visible: 0, maxChipWidth: maxChipWidth);
}

/// The largest cap, up to [ceiling], at which [widths] — each clipped to the
/// cap — still sum to no more than [space].
double _waterLevel(List<double> widths, double space, double ceiling) {
  final sorted = [...widths]..sort();
  var remaining = space;
  for (var i = 0; i < sorted.length; i++) {
    final share = remaining / (sorted.length - i);
    if (sorted[i] > share) return share;
    remaining -= sorted[i];
  }
  return ceiling;
}

/// Copies [snippet]'s description exactly as stored — an empty one included —
/// and names it in the toast. [overlay] is read by the caller before anything
/// async, for the same reason [_ProfileCopyButton] reads its own.
Future<void> _copyExperience(
  OverlayState overlay,
  JobExperienceSnippet snippet,
) async {
  await Clipboard.setData(ClipboardData(text: snippet.description));
  showVoyagerToastIn(
    overlay,
    message: '${snippet.name} copied',
    icon: PhosphorIconsRegular.check,
    dwell: const Duration(seconds: 2),
  );
}

/// One-tap copies of the user's experience snippets
/// (`JOBS_EXPERIENCE_SNIPPETS_HLD.md` §7).
///
/// Text chips rather than icons: a role has no glyph. Up to three, in the
/// user's order — as many as [budget] fits at a readable width — and the rest
/// behind a caret menu, so a narrow window loses chips rather than the chart.
class _ExperienceCopyButtons extends StatelessWidget {
  const _ExperienceCopyButtons({required this.snippets, required this.budget});

  final List<JobExperienceSnippet> snippets;
  final double budget;

  static double _textWidth(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    // Rounded up so a chip given exactly its natural width never ellipsizes
    // over a fraction of a pixel.
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    // Merged the way [Text] merges it, so the measured width is the drawn one.
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(_ExperienceChip.labelStyle(Theme.of(context)));
    final scaler = MediaQuery.textScalerOf(context);
    final layout = layoutExperienceChips(
      naturalWidths: [
        for (final snippet in snippets.take(_kMaxExperienceChips))
          _ExperienceChip.chrome + _textWidth(snippet.name, style, scaler),
      ],
      total: snippets.length,
      budget: budget,
    );
    final shown = snippets.take(layout.visible).toList();
    final hidden = snippets.skip(layout.visible).toList();

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const SizedBox(width: _kExperienceChipGap),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.maxChipWidth),
              child: _ExperienceChip(snippet: shown[i]),
            ),
          ],
          if (hidden.isNotEmpty) ...[
            if (shown.isNotEmpty) const SizedBox(width: _kExperienceChipGap),
            _ExperienceOverflowButton(
              snippets: hidden,
              allHidden: shown.isEmpty,
            ),
          ],
        ],
      ),
    );
  }
}

class _ExperienceChip extends StatelessWidget {
  const _ExperienceChip({required this.snippet});

  final JobExperienceSnippet snippet;

  static const double _horizontalPadding = 10;
  static const double _border = 1;
  static const double _iconSize = 12;
  static const double _iconGap = 5;

  /// Everything in a chip but its label, for measuring it before layout.
  static const double chrome =
      (_horizontalPadding + _border) * 2 + _iconSize + _iconGap;

  static TextStyle? labelStyle(ThemeData theme) => theme.textTheme.labelSmall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The name only: the description never appears on the Jobs page.
    return Tooltip(
      message: 'Copy ${snippet.name}',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () =>
              _copyExperience(Overlay.of(context, rootOverlay: true), snippet),
          borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: _horizontalPadding,
              vertical: 5,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.4,
              ),
              borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
                width: _border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  PhosphorIconsRegular.copy,
                  size: _iconSize,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: _iconGap),
                Flexible(
                  child: Text(
                    snippet.name,
                    style: labelStyle(theme),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
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

class _ExperienceOverflowButton extends StatelessWidget {
  const _ExperienceOverflowButton({
    required this.snippets,
    required this.allHidden,
  });

  final List<JobExperienceSnippet> snippets;

  /// No chip made it onto the row, so this button is the whole group.
  final bool allHidden;

  Future<void> _open(BuildContext context) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final picked = await showContextualPopover<JobExperienceSnippet>(
      context: context,
      buttonContext: context,
      width: 280,
      builder: (_) => _ExperienceMenu(snippets: snippets),
    );
    if (picked != null) await _copyExperience(overlay, picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: allHidden ? 'Copy an experience' : 'More experiences',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => _open(context),
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: _kExperienceOverflowWidth,
            height: _kExperienceOverflowWidth,
            child: Icon(
              PhosphorIconsRegular.caretDown,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The overflow list. Names wrap rather than ellipsize: this is where a name
/// too long for its chip is read in full.
class _ExperienceMenu extends StatelessWidget {
  const _ExperienceMenu({required this.snippets});

  final List<JobExperienceSnippet> snippets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: VoyagerScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final snippet in snippets)
              InkWell(
                onTap: () => Navigator.of(context).pop(snippet),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        PhosphorIconsRegular.copy,
                        size: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          snippet.name,
                          style: theme.textTheme.bodySmall,
                        ),
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

class _LabelledChart extends StatelessWidget {
  const _LabelledChart({required this.label, required this.child});

  /// Thirty days spread across the header's full half stretch the line into a
  /// near-flat drift rather than a chart; capped, a day is ~8.7px and the
  /// day-to-day swings are steep enough to read.
  static const double _maxWidth = 260;

  /// The least the experience chips may leave the chart. Below this the
  /// 30 days stop reading as a trend, so chips give way to the overflow menu
  /// first. Profile icons alone can still push it narrower.
  static const double minWidth = 140;

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      // Shrink-wrap: an Align handed a bounded width otherwise fills it, and
      // the header's copy buttons, packed in just before this, would sit at
      // the far side of that slack instead of against the chart.
      widthFactor: 1,
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

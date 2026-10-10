import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/job_clipboard_parser.dart';
import 'package:voyager/features/jobs/jobs_providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// Relative widths of the flat table's free-text columns (§3.2). Color is a
/// fixed-width swatch gutter, and Status and Date applied are sized to what
/// they show — see [jobColumnWidths].
const _columnFlex = <JobColumn, int>{
  JobColumn.company: 2,
  JobColumn.title: 5,
  JobColumn.season: 2,
  JobColumn.notes: 4,
};

const _colorColumnWidth = 22.0;
const _warningColumnWidth = 22.0;
const _archiveColumnWidth = 28.0;
const _rowHorizontalPadding = 20.0;

/// The space after every cell.
const _cellGap = 12.0;

/// A status capsule's padding and border, around its label.
const _statusCapsuleChrome = 8.0 * 2 + 2;

/// The widest a status capsule grows; a longer stage name ellipsizes.
const _statusCapsuleMaxWidth = 160.0;

TextStyle? _headerStyle(ThemeData theme) =>
    theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

String _dateLabel(JobApplication application) =>
    DateFormat.yMMMd().format(jobDayKey(application.dateApplied));

String _statusLabel(JobApplication application) =>
    application.status.isEmpty ? '—' : application.status;

/// What [jobColumnWidths] needs measured, none of which depends on the
/// table's width: each shown column's header, and the widest date and status
/// capsule among the rows.
class JobColumnMeasures {
  const JobColumnMeasures._({required this.floors, required this.content});

  /// Each shown column's header width, its trailing gap included — the
  /// narrowest a free-text column goes while there is room.
  final Map<JobColumn, double> floors;

  /// Date applied's and Status's widths, sized to the widest of their values.
  final Map<JobColumn, double> content;
}

/// Measures for [jobColumnWidths], kept until the columns, the labels or the
/// text style change. Laying text out is the costly part: the table's width
/// changes every frame while the editor panel slides, and the page rebuilds
/// on a selection or a keystroke in search.
class JobColumnMeasurer {
  _MeasureKey? _key;
  JobColumnMeasures? _measures;

  JobColumnMeasures measure(
    BuildContext context, {
    required List<JobColumn> columns,
    required List<JobApplication> rows,
  }) {
    final theme = Theme.of(context);
    final key = _MeasureKey(
      columns: columns,
      dates: {
        if (columns.contains(JobColumn.dateApplied))
          for (final row in rows) _dateLabel(row),
      },
      statuses: {
        if (columns.contains(JobColumn.status))
          for (final row in rows) _statusLabel(row),
      },
      base: DefaultTextStyle.of(context).style,
      headerStyle: _headerStyle(theme),
      dateStyle: theme.textTheme.bodySmall,
      statusStyle: theme.textTheme.labelSmall,
      scaler: MediaQuery.textScalerOf(context),
    );
    final cached = _measures;
    if (cached != null && key == _key) return cached;
    _key = key;
    return _measures = _measureJobColumns(key);
  }
}

class _MeasureKey {
  const _MeasureKey({
    required this.columns,
    required this.dates,
    required this.statuses,
    required this.base,
    required this.headerStyle,
    required this.dateStyle,
    required this.statusStyle,
    required this.scaler,
  });

  final List<JobColumn> columns;
  final Set<String> dates;
  final Set<String> statuses;
  final TextStyle base;
  final TextStyle? headerStyle;
  final TextStyle? dateStyle;
  final TextStyle? statusStyle;
  final TextScaler scaler;

  @override
  bool operator ==(Object other) =>
      other is _MeasureKey &&
      listEquals(other.columns, columns) &&
      setEquals(other.dates, dates) &&
      setEquals(other.statuses, statuses) &&
      other.base == base &&
      other.headerStyle == headerStyle &&
      other.dateStyle == dateStyle &&
      other.statusStyle == statusStyle &&
      other.scaler == scaler;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(columns),
    dates.length,
    statuses.length,
    base,
    headerStyle,
    dateStyle,
    statusStyle,
    scaler,
  );
}

JobColumnMeasures _measureJobColumns(_MeasureKey key) {
  double measure(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: key.base.merge(style)),
      textDirection: TextDirection.ltr,
      textScaler: key.scaler,
      maxLines: 1,
    )..layout();
    // Rounded up so a cell given exactly its text's width never ellipsizes
    // over a fraction of a pixel.
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  final floors = {
    for (final column in key.columns)
      if (column != JobColumn.color)
        column: measure(column.label, key.headerStyle) + _cellGap,
  };
  final content = <JobColumn, double>{};
  if (floors.containsKey(JobColumn.dateApplied)) {
    var widest = floors[JobColumn.dateApplied]!;
    for (final label in key.dates) {
      widest = math.max(widest, measure(label, key.dateStyle) + _cellGap);
    }
    content[JobColumn.dateApplied] = widest;
  }
  if (floors.containsKey(JobColumn.status)) {
    var widest = floors[JobColumn.status]!;
    for (final label in key.statuses) {
      final capsule = measure(label, key.statusStyle) + _statusCapsuleChrome;
      widest = math.max(
        widest,
        math.min(capsule, _statusCapsuleMaxWidth) + _cellGap,
      );
    }
    content[JobColumn.status] = widest;
  }
  return JobColumnMeasures._(floors: floors, content: content);
}

/// Each shown column's width, its trailing gap included, for a table
/// [tableWidth] wide (BUG-181).
///
/// Date applied and Status take the width of the widest date and status
/// capsule among the rows, so neither is cut when the editor panel or a small
/// window narrows the table. The free-text columns share what is left by
/// [_columnFlex], none narrower than its own header, which would otherwise
/// break mid-word. When even that doesn't fit they share it and ellipsize,
/// down to half their headers' width; narrower still, every column gives way
/// in proportion, so none is squeezed out altogether.
Map<JobColumn, double> jobColumnWidths(
  JobColumnMeasures measures, {
  required double tableWidth,
  required List<JobColumn> columns,
}) {
  final floors = measures.floors;
  final widths = Map.of(measures.content);
  final flexible = [
    for (final column in columns)
      if (column != JobColumn.color && !widths.containsKey(column)) column,
  ];

  final available =
      tableWidth -
      _rowHorizontalPadding * 2 -
      _warningColumnWidth -
      (columns.contains(JobColumn.color) ? _colorColumnWidth : 0) -
      _archiveColumnWidth;
  final fixed = widths.values.fold<double>(0, (sum, width) => sum + width);
  final keep =
      flexible.fold<double>(0, (sum, column) => sum + floors[column]!) / 2;
  var rest = available - fixed;
  if (rest < keep) {
    final scale = math.max(0.0, available) / (fixed + keep);
    widths.updateAll((_, width) => width * scale);
    rest = keep * scale;
  }
  // Water-fill: a column whose share is under its header takes the header's
  // width, and the rest share what that leaves.
  while (true) {
    final totalFlex = flexible.fold<int>(
      0,
      (sum, column) => sum + _columnFlex[column]!,
    );
    final short = [
      for (final column in flexible)
        if (rest * _columnFlex[column]! / totalFlex < floors[column]!) column,
    ];
    final shortFloors = short.fold<double>(
      0,
      (sum, column) => sum + floors[column]!,
    );
    if (short.isEmpty ||
        short.length == flexible.length ||
        shortFloors > rest) {
      for (final column in flexible) {
        widths[column] = rest * _columnFlex[column]! / totalFlex;
      }
      return widths;
    }
    for (final column in short) {
      widths[column] = floors[column]!;
      rest -= floors[column]!;
      flexible.remove(column);
    }
  }
}

class JobsTableHeader extends StatelessWidget {
  const JobsTableHeader({
    super.key,
    required this.columns,
    required this.widths,
  });

  final List<JobColumn> columns;

  /// From [jobColumnWidths].
  final Map<JobColumn, double> widths;

  @override
  Widget build(BuildContext context) {
    final style = _headerStyle(Theme.of(context));
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _rowHorizontalPadding,
        0,
        _rowHorizontalPadding,
        6,
      ),
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
              SizedBox(
                width: widths[column],
                child: Padding(
                  padding: const EdgeInsets.only(right: _cellGap),
                  child: Text(
                    column.label,
                    style: style,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          const SizedBox(width: _archiveColumnWidth),
        ],
      ),
    );
  }
}

/// The right-click menu for one application row.
///
/// Built by the page, which is the only place that knows the stage and season
/// lists these submenus offer. "Open application URL" is absent rather than
/// disabled when there is no URL it would open — an entry that can never do
/// anything is noise, not information.
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
        // By name, once each: two stages sharing a name are one status.
        for (final name in {for (final stage in stages) stage.name})
          ContextMenuItem(
            label: name,
            trailing: name == application.status
                ? const Icon(PhosphorIconsRegular.check, size: 13)
                : null,
            onTap: () => onChangeStatus(name),
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
    if (launchableJobUri(url) != null)
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
    required this.widths,
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

  /// From [jobColumnWidths].
  final Map<JobColumn, double> widths;

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
            padding: const EdgeInsets.symmetric(
              horizontal: _rowHorizontalPadding,
              vertical: 9,
            ),
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
                    SizedBox(
                      width: widths[column],
                      child: Padding(
                        padding: const EdgeInsets.only(right: _cellGap),
                        child: _cell(context, column),
                      ),
                    ),
                SizedBox(
                  width: _archiveColumnWidth,
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
                borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(
                      VoyagerTheme.fieldRadius,
                    ),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    _statusLabel(application),
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
          _dateLabel(application),
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
        return VoyagerProseText(
          preview,
          style: muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
  }
}

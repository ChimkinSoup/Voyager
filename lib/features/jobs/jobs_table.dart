import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_providers.dart';

/// Relative widths of the flat table's columns (§3.2). Color is a fixed-width
/// swatch gutter; the rest share the remaining space by flex.
const _columnFlex = <JobColumn, int>{
  JobColumn.company: 3,
  JobColumn.title: 4,
  JobColumn.status: 2,
  JobColumn.dateApplied: 2,
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

class JobsTableRow extends StatelessWidget {
  const JobsTableRow({
    super.key,
    required this.application,
    required this.columns,
    required this.color,
    required this.isDuplicate,
    required this.isSelected,
    required this.seasonName,
    required this.onTap,
  });

  final JobApplication application;
  final List<JobColumn> columns;

  /// The category colour of the application's company, or the neutral default
  /// when the company is uncategorised or unrecognised (§4.5).
  final Color color;

  /// Another row shares this company+title (§7.3). Informational only.
  final bool isDuplicate;
  final bool isSelected;

  /// Non-null when the application is archived and the list is showing
  /// archived rows, so the row can say which season it is filed under (§6.3).
  final String? seasonName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
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
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
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
                            'Another application has the same company and '
                            'title',
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
                child: application.isArchived
                    ? Tooltip(
                        message: seasonName == null
                            ? 'Archived'
                            : 'Archived — $seasonName',
                        child: Icon(
                          PhosphorIconsRegular.archive,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      )
                    : null,
              ),
            ],
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
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              application.status.isEmpty ? '—' : application.status,
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      case JobColumn.dateApplied:
        return Text(
          DateFormat.yMMMd().format(application.dateApplied.toLocal()),
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

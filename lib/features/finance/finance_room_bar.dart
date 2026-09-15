import 'package:flutter/material.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/finance_models.dart';

/// [formatCents] without the `.00` on a whole-dollar figure, so `X/Y` fits
/// inside a bar without rounding a nearly full room up to look full.
String _barCents(int cents) {
  final text = formatNetCents(cents);
  return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
}

/// Room used against capacity for the current year: a slim bar with `X/Y`
/// printed inside, turning to the error colour with an over-by note once the
/// room is over-contributed.
class ContributionRoomBar extends StatelessWidget {
  const ContributionRoomBar({
    super.key,
    required this.summary,
    required this.color,
  });

  final RoomYearSummary summary;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = summary.isOver;
    final capacity = summary.capacityCents;
    final used = summary.usedCents;
    final fraction = over
        ? 1.0
        : capacity > 0
        ? (used / capacity).clamp(0.0, 1.0)
        : 0.0;
    final fill = over ? theme.colorScheme.error : color;
    final remainingLabel = over
        ? 'Over by ${formatCents(-summary.remainingCents)}'
        : 'Remaining ${formatCents(summary.remainingCents)}';

    final bar = SizedBox(
      height: 14,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(7),
              ),
            ),
          ),
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fill.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '${_barCents(used)}/${_barCents(capacity)}',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 9.5,
                height: 1,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: '${_barCents(used)} of ${_barCents(capacity)} used. '
          '$remainingLabel',
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(
            // Manual: the default long-press trigger would win the gesture
            // arena and swallow the row's long-press menu.
            child: Tooltip(
              message: remainingLabel,
              triggerMode: TooltipTriggerMode.manual,
              child: bar,
            ),
          ),
          if (over) ...[
            const SizedBox(width: 8),
            Text(
              remainingLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

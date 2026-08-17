import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';
import 'package:voyager/features/leetcode/leetcode_activity_data.dart';

/// Month tiles per row, by how much width the calendar has been given. The
/// analytics year calendar pins this at three; this one is shown inside an
/// overlay that can be as narrow as a phone, where three tiles put four
/// pixels under each day.
int _columnsFor(double width) {
  if (width >= 1000) return 4;
  if (width >= 700) return 3;
  if (width >= 420) return 2;
  return 1;
}

const _monthNames = [
  '',
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// A year of solving at a glance: every day tinted by how many problems it
/// holds, in the app's accent rather than per difficulty, with the difficulty
/// breakdown reserved for the hover bubble.
///
/// One colour is the point. The sparkline above it already splits the three
/// tiers apart; this view answers the other question — which days did any work
/// happen at all — and three-colour squares would have made that unreadable.
///
/// [difficulty] is the sparkline legend's selection reaching down here: the
/// grid counts only that tier and tints in that tier's colour, so a click up
/// top re-reads the whole page rather than half of it. The scale rebases with
/// it — see [leetCodeBusiestDayInYear].
class LeetCodeActivityCalendar extends ConsumerStatefulWidget {
  const LeetCodeActivityCalendar({
    super.key,
    required this.byDay,
    this.difficulty,
  });

  final Map<DateTime, LeetCodeDayCounts> byDay;
  final LeetCodeDifficulty? difficulty;

  @override
  ConsumerState<LeetCodeActivityCalendar> createState() =>
      _LeetCodeActivityCalendarState();
}

/// The hovered day and where the pointer is in the grid's own coordinates,
/// which is what the bubble is laid out against.
typedef _CalendarHover = ({DateTime date, Offset position});

class _LeetCodeActivityCalendarState
    extends ConsumerState<LeetCodeActivityCalendar> {
  final _stackKey = GlobalKey();

  late int _year = DateTime.now().year;

  /// Hover lives in a notifier rather than in [State] so that moving the
  /// pointer rebuilds the bubble and nothing else. A `setState` here rebuilt
  /// the whole year — twelve month tiles of forty-two day cells — for every
  /// pointer event, ~1900 widgets per mouse move, which dropped frames on its
  /// own before anything got as far as painting.
  final _hover = ValueNotifier<_CalendarHover?>(null);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  void _onHover(DateTime date, Offset globalPosition) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // Records compare by value, so a pointer event that resolves to the same
    // day and position notifies nobody.
    _hover.value = (date: date, position: box.globalToLocal(globalPosition));
  }

  /// Only the cell that is still the hovered one may clear the bubble — the
  /// pointer enters the next cell before it exits the last, so an unguarded
  /// exit would blank a bubble that had just been raised.
  void _endHover(DateTime date) {
    if (_hover.value?.date != date) return;
    _hover.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weekStartsMonday =
        ref.watch(settingsProvider).valueOrNull?.weekStartsOnMonday ?? true;
    final busiest = leetCodeBusiestDayInYear(
      widget.byDay,
      _year,
      difficulty: widget.difficulty,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous year',
              onPressed: () => setState(() => _year--),
            ),
            Text(
              '$_year',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next year',
              onPressed: () => setState(() => _year++),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: VoyagerScrollView(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = _columnsFor(constraints.maxWidth);
                final rows = (12 / columns).ceil();
                return Stack(
                  key: _stackKey,
                  clipBehavior: Clip.none,
                  children: [
                    // The grid no longer rebuilds as the pointer moves; this
                    // keeps it from *repainting* either, since otherwise the
                    // bubble sliding a pixel redraws five hundred rounded
                    // cells through twelve antialiased card clips.
                    RepaintBoundary(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var row = 0; row < rows; row++) ...[
                            if (row > 0) const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var col = 0; col < columns; col++) ...[
                                  if (col > 0) const SizedBox(width: 8),
                                  Expanded(
                                    child: row * columns + col < 12
                                        ? _MonthTile(
                                            month: DateTime(
                                              _year,
                                              row * columns + col + 1,
                                            ),
                                            byDay: widget.byDay,
                                            busiest: busiest,
                                            difficulty: widget.difficulty,
                                            weekStartsMonday: weekStartsMonday,
                                            onHover: _onHover,
                                            onHoverEnd: _endHover,
                                          )
                                        // Keeps the last row's tiles the same
                                        // width as every other row's rather
                                        // than stretching them across the gap.
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    ValueListenableBuilder<_CalendarHover?>(
                      valueListenable: _hover,
                      builder: (context, hover, _) {
                        if (hover == null) return const SizedBox.shrink();
                        return LeetCodeActivityBubbleLayer(
                          anchor: hover.position,
                          child: LeetCodeActivityBubble(
                            date: hover.date,
                            counts:
                                widget.byDay[hover.date] ??
                                LeetCodeDayCounts.zero,
                            // The grid is counting one tier while the filter
                            // is on, so its bubble reads the same way.
                            only: widget.difficulty,
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({
    required this.month,
    required this.byDay,
    required this.busiest,
    required this.difficulty,
    required this.weekStartsMonday,
    required this.onHover,
    required this.onHoverEnd,
  });

  final DateTime month;
  final Map<DateTime, LeetCodeDayCounts> byDay;
  final int busiest;
  final LeetCodeDifficulty? difficulty;
  final bool weekStartsMonday;
  final void Function(DateTime date, Offset globalPosition) onHover;
  final ValueChanged<DateTime> onHoverEnd;

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: chartTooltipBubbleColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final daySize = constraints.maxWidth / 7;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _monthNames[month.month],
                  style: MonthTitleHeader.yearTileMonthNameStyle(context),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textHeightBehavior: MonthTitleHeader.titleTextHeightBehavior,
                ),
                const SizedBox(height: MonthTitleHeader.titleGap),
                WeekdayHeaderRow(
                  weekStartsMonday: weekStartsMonday,
                  useSingleLetterLabels: false,
                  labelStyle: calendarWeekdayLabelStyle(
                    context,
                    fontSize: MonthDayCellStyle.compact.fontSize,
                  ),
                ),
                const SizedBox(height: monthDayGridWeekdayHeaderGap),
                for (var row = 0; row < 6; row++)
                  Row(
                    children: [
                      for (var col = 0; col < 7; col++)
                        SizedBox(
                          width: daySize,
                          height: daySize,
                          child: _DayCell(
                            date: cells[row * 7 + col],
                            month: month,
                            counts: byDay[cells[row * 7 + col]],
                            busiest: busiest,
                            difficulty: difficulty,
                            onHover: onHover,
                            onHoverEnd: onHoverEnd,
                          ),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.month,
    required this.counts,
    required this.busiest,
    required this.difficulty,
    required this.onHover,
    required this.onHoverEnd,
  });

  final DateTime date;
  final DateTime month;
  final LeetCodeDayCounts? counts;
  final int busiest;
  final LeetCodeDifficulty? difficulty;
  final void Function(DateTime date, Offset globalPosition) onHover;
  final ValueChanged<DateTime> onHoverEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Unfiltered the grid stays in the app's accent — "some work happened" is
    // one question with one colour. Filtered, it borrows the tier's own colour
    // so the squares and the curve above them are obviously the same series.
    final accent = difficulty == null
        ? theme.colorScheme.primary
        : colorForLeetCodeDifficulty(difficulty!);
    final inMonth = date.month == month.month && date.year == month.year;
    final total = difficulty == null
        ? counts?.total ?? 0
        : counts?.countFor(difficulty!) ?? 0;
    // Days spilling in from an adjacent month stay neutral, exactly as they do
    // on the analytics year heatmap: only the days that belong to this tile
    // light up, and each of them lights up in its own month's tile.
    final lit = inMonth && total > 0;
    final intensity = busiest <= 0 ? 0.0 : (total / busiest).clamp(0.0, 1.0);
    final fade = inMonth ? 1.0 : 0.4;

    return MouseRegion(
      // Empty days are hoverable too — "nothing that day" is an answer, and a
      // grid where only some squares respond feels broken.
      onEnter: (event) {
        if (inMonth) onHover(date, event.position);
      },
      onHover: (event) {
        if (inMonth) onHover(date, event.position);
      },
      onExit: (_) => onHoverEnd(date),
      child: Container(
        margin: const EdgeInsets.all(1),
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: lit
              ? accent.withValues(alpha: 0.15 + 0.85 * intensity)
              : theme.colorScheme.onSurface.withValues(alpha: 0.05 * fade),
          borderRadius: BorderRadius.circular(
            MonthDayCellStyle.compact.borderRadius,
          ),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            '${date.day}',
            style: TextStyle(
              fontSize: MonthDayCellStyle.compact.fontSize,
              fontWeight: FontWeight.w500,
              color: inMonth
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: calendarAdjacentMonthTextOpacity,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

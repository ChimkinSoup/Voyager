import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
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

/// Diameter of the review marker in the day cell's bottom-right corner. Small
/// enough to clear the date label at the tightest cell size the grid reaches.
const double _reviewRingSize = 5;

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
/// holds, in the app's accent rather than per difficulty, with the full
/// breakdown — the three tiers and the day's reviews — reserved for the hover
/// bubble.
///
/// One colour is the point. The sparkline above it already splits the series
/// apart; this view answers the other question — which days did any work
/// happen at all — and multi-colour squares would have made that unreadable.
/// Unfiltered it counts solves only, for the same reason: mixing reviews into
/// the tint would stop the grid meaning one thing.
///
/// [series] is the sparkline legend's selection reaching down here: the grid
/// counts only that series and tints in its colour, so a click up top re-reads
/// the whole page rather than half of it. The scale rebases with it — see
/// [leetCodeBusiestDayInYear].
class LeetCodeActivityCalendar extends ConsumerStatefulWidget {
  const LeetCodeActivityCalendar({super.key, required this.byDay, this.series});

  final Map<DateTime, LeetCodeDayCounts> byDay;
  final LeetCodeActivitySeries? series;

  @override
  ConsumerState<LeetCodeActivityCalendar> createState() =>
      _LeetCodeActivityCalendarState();
}

/// The hovered day, where the pointer is in the grid's own coordinates — which
/// is what the bubble is laid out against — and the band of those coordinates
/// the year is actually being shown through. The grid scrolls, so the space
/// above the pointer inside the stack is not necessarily space on screen.
typedef _CalendarHover = ({
  DateTime date,
  Offset position,
  double visibleTop,
  double visibleBottom,
});

class _LeetCodeActivityCalendarState
    extends ConsumerState<LeetCodeActivityCalendar> {
  final _stackKey = GlobalKey();
  final _scrollController = ScrollController();

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
    _scrollController.dispose();
    super.dispose();
  }

  void _onHover(DateTime date, Offset globalPosition) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // Read on every move rather than watched: the pointer has to move for a
    // bubble to exist at all, so the metrics are never staler than the hover
    // they travel with.
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final visibleTop = position?.pixels ?? 0.0;
    // Records compare by value, so a pointer event that resolves to the same
    // day and position notifies nobody.
    _hover.value = (
      date: date,
      position: box.globalToLocal(globalPosition),
      visibleTop: visibleTop,
      visibleBottom:
          visibleTop + (position?.viewportDimension ?? box.size.height),
    );
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
      series: widget.series,
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
            controller: _scrollController,
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
                                            series: widget.series,
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
                          visibleTop: hover.visibleTop,
                          visibleBottom: hover.visibleBottom,
                          child: LeetCodeActivityBubble(
                            date: hover.date,
                            counts:
                                widget.byDay[hover.date] ??
                                LeetCodeDayCounts.zero,
                            // The grid is counting one series while the filter
                            // is on, so its bubble reads the same way.
                            only: widget.series,
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
    required this.series,
    required this.weekStartsMonday,
    required this.onHover,
    required this.onHoverEnd,
  });

  final DateTime month;
  final Map<DateTime, LeetCodeDayCounts> byDay;
  final int busiest;
  final LeetCodeActivitySeries? series;
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
                            series: series,
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
    required this.series,
    required this.onHover,
    required this.onHoverEnd,
  });

  final DateTime date;
  final DateTime month;
  final LeetCodeDayCounts? counts;
  final int busiest;
  final LeetCodeActivitySeries? series;
  final void Function(DateTime date, Offset globalPosition) onHover;
  final ValueChanged<DateTime> onHoverEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Unfiltered the grid stays in the app's accent — "some work happened" is
    // one question with one colour. Filtered, it borrows the series' own colour
    // so the squares and the curve above them are obviously the same line.
    final accent = series == null
        ? theme.colorScheme.primary
        : colorForLeetCodeActivitySeries(context, series!);
    final inMonth = date.month == month.month && date.year == month.year;
    final total = series == null
        ? counts?.total ?? 0
        : counts?.countForSeries(series!) ?? 0;
    // Days spilling in from an adjacent month stay neutral, exactly as they do
    // on the analytics year heatmap: only the days that belong to this tile
    // light up, and each of them lights up in its own month's tile.
    final lit = inMonth && total > 0;
    final intensity = busiest <= 0 ? 0.0 : (total / busiest).clamp(0.0, 1.0);
    final fade = inMonth ? 1.0 : 0.4;
    // Reviews stay out of the tint — the square's intensity is a count of
    // solves, and mixing the two would stop the scale meaning one thing — so a
    // day of nothing but review work would otherwise read as blank. A ring in
    // the free corner says work happened without touching the scale. Only
    // unfiltered: with a series selected the tint is already the answer.
    final reviewed = series == null && inMonth && (counts?.reviews ?? 0) > 0;

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
        child: Stack(
          children: [
            Align(
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
            if (reviewed)
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  width: _reviewRingSize,
                  height: _reviewRingSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      // The accent is user-chosen and can land anywhere on the
                      // luminance range, so neither ink works on both backings:
                      // a heavily tinted square is essentially the accent, where
                      // onPrimary is the one colour guaranteed to read, while a
                      // pale or empty one is essentially the card, where the
                      // theme's own ink is.
                      color: intensity >= 0.5 && lit
                          ? theme.colorScheme.onPrimary.withValues(alpha: 0.7)
                          : theme.colorScheme.onSurface.withValues(alpha: 0.45),
                      width: 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

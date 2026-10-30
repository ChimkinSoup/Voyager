import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';

/// The size to open [DateSelectorPopover] at. Its day grid hangs off an
/// Expanded, so it needs a fixed height, and this one fits all six week rows
/// under the quick picks, month header and weekday labels.
const kDateSelectorPopoverSize = Size(320, 400);

/// Builds a quick pick (Today, Tomorrow, Next Week) in a host's own look;
/// [selected] when it's the picked day, and [onPressed] null when it's out
/// of the picker's range.
typedef QuickPickBuilder =
    Widget Function(String label, bool selected, VoidCallback? onPressed);

/// Opens a [DateSelectorPopover] off [buttonContext] for one day, from
/// [firstDate] to [lastDate] when given. Null when closed without a pick.
Future<DateTime?> showDayPickerPopover({
  required BuildContext context,
  required BuildContext buttonContext,
  required DateTime initial,
  Color? accentColor,
  DateTime? firstDate,
  DateTime? lastDate,
}) => showContextualPopover<DateTime>(
  context: context,
  buttonContext: buttonContext,
  // Both are needed: the calendar hangs its grid off an Expanded, so a
  // popover left to size itself gives that grid no height at all.
  width: kDateSelectorPopoverSize.width,
  height: kDateSelectorPopoverSize.height,
  accentColor: accentColor,
  builder: (context) => DateSelectorPopover(
    initialStartDate: initial,
    initialEndDate: initial,
    singleDateMode: true,
    inlineMode: true,
    accentColor: accentColor,
    firstDate: firstDate,
    lastDate: lastDate,
    onDateSelected: (date) => Navigator.of(context).pop(date),
  ),
);

class DateSelectorPopover extends ConsumerStatefulWidget {
  final DateTime initialStartDate;
  final DateTime initialEndDate;
  final bool singleDateMode;
  final bool inlineMode;
  final ValueChanged<DateTime>? onDateSelected;
  final Color? accentColor;

  /// Replaces the quick-pick chips, which then keep to one line, scaled
  /// down if they must.
  final QuickPickBuilder? quickPickBuilder;

  /// The first and last days that can be picked, either open when null.
  /// Days and quick picks outside them are greyed out.
  final DateTime? firstDate;
  final DateTime? lastDate;

  const DateSelectorPopover({
    super.key,
    required this.initialStartDate,
    required this.initialEndDate,
    this.singleDateMode = false,
    this.inlineMode = false,
    this.onDateSelected,
    this.accentColor,
    this.quickPickBuilder,
    this.firstDate,
    this.lastDate,
  });

  @override
  ConsumerState<DateSelectorPopover> createState() =>
      _DateSelectorPopoverState();
}

class _DateSelectorPopoverState extends ConsumerState<DateSelectorPopover>
    with SingleTickerProviderStateMixin {
  late DateTime _focusedMonth;
  // Turning the month scrolls the grid as one strip of weeks: it starts
  // [_scrollFromWeeks] rows off the new month's grid and eases to it, while
  // each day's ink fades from its [_inkFrom] to the new month's.
  late final AnimationController _scroll = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1,
  );
  double _scrollFromWeeks = 0;
  // The ink each month's days had when the fade began, by its first day;
  // a month left out had the greyed-out ink.
  Map<DateTime, double> _inkFrom = {};
  late DateTime _hoveredDate; // Used for VIM navigation focus
  DateTime? _firstSelected;
  DateTime? _secondSelected;
  bool _awaitingRangeEnd = false;
  late final FocusNode _focusNode;
  bool _canPop = false;
  bool _showHoverRing = false;

  @override
  void initState() {
    super.initState();
    // Once a scroll settles, drop the weeks it carried out of view.
    _scroll.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _scrollFromWeeks = 0);
      }
    });
    _hoveredDate = widget.initialStartDate;
    _focusedMonth = DateTime(_hoveredDate.year, _hoveredDate.month, 1);

    _firstSelected = widget.initialStartDate;
    if (widget.initialStartDate.year != widget.initialEndDate.year ||
        widget.initialStartDate.month != widget.initialEndDate.month ||
        widget.initialStartDate.day != widget.initialEndDate.day) {
      _secondSelected = widget.initialEndDate;
    }

    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DateSelectorPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStartDate != oldWidget.initialStartDate ||
        widget.initialEndDate != oldWidget.initialEndDate) {
      // A range started against the old dates would close from the new start.
      _awaitingRangeEnd = false;
      if (widget.initialStartDate != _firstSelected) {
        _firstSelected = widget.initialStartDate;
        if (_focusedMonth.year != _firstSelected!.year ||
            _focusedMonth.month != _firstSelected!.month) {
          _setFocusedMonth(
            DateTime(_firstSelected!.year, _firstSelected!.month, 1),
          );
        }
      }
      if (widget.initialStartDate.year != widget.initialEndDate.year ||
          widget.initialStartDate.month != widget.initialEndDate.month ||
          widget.initialStartDate.day != widget.initialEndDate.day) {
        _secondSelected = widget.initialEndDate;
      } else {
        _secondSelected = null;
      }
    }
  }

  bool get _weekStartsMonday =>
      ref.read(settingsProvider.settled).valueOrNull?.weekStartsOnMonday ??
      true;

  double get _scrollT => Curves.easeOutCubic.transform(_scroll.value);

  /// How many rows the grid sits off the focused month's, mid-scroll.
  double get _scrollWeeks => _scrollFromWeeks * (1 - _scrollT);

  void _setFocusedMonth(DateTime month) {
    if (month == _focusedMonth) return;
    final weekStartsMonday = _weekStartsMonday;
    final weeks =
        calendarDaysBetween(
          calendarWeekStart(month, weekStartsMonday),
          calendarWeekStart(_focusedMonth, weekStartsMonday),
        ) /
        7;
    // Each day's ink picks up from where an unfinished fade has got to. A
    // month the last fade finished greying is back to the default, so it is
    // left out rather than compared against 0.3, which the lerp misses.
    final fade = _scroll.value;
    _inkFrom = {
      for (final m in {..._inkFrom.keys, _focusedMonth})
        if (m == _focusedMonth || fade < 1)
          m: _lerpInk(_inkFrom[m] ?? 0.3, m == _focusedMonth ? 1.0 : 0.3, fade),
    };
    // The scroll picks up from wherever an unfinished one has got to, so quick
    // turns run on rather than restart. A jump past a grid's height snaps:
    // there's no strip worth scrolling. For the same reason a run of quick
    // turns starts at most a grid away, or the strip would build every week
    // they piled up.
    final fromWeeks = (_scrollWeeks + weeks).clamp(-6.0, 6.0);
    _focusedMonth = month;
    if (weeks.abs() > 6) {
      _inkFrom = {};
      _scrollFromWeeks = 0;
      _scroll.value = 1;
    } else {
      _scrollFromWeeks = fromWeeks;
      _scroll.forward(from: 0);
    }
  }

  static double _lerpInk(double from, double to, double t) =>
      from + (to - from) * t;

  void _previousMonth() {
    setState(() {
      _setFocusedMonth(
        DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1),
      );
    });
  }

  void _nextMonth() {
    setState(() {
      _setFocusedMonth(
        DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1),
      );
    });
  }

  bool _inRange(DateTime date) {
    final day = DateUtils.dateOnly(date);
    final first = widget.firstDate;
    final last = widget.lastDate;
    return (first == null || !day.isBefore(DateUtils.dateOnly(first))) &&
        (last == null || !day.isAfter(DateUtils.dateOnly(last)));
  }

  void _handleDateTap(DateTime date, {bool startsRange = false}) {
    if (!_inRange(date)) return;
    setState(() {
      _hoveredDate = date;
      // A plain tap picks one day. Shift+tap, or a long press on touch,
      // starts a fresh range at the tapped day, and the next tap — Shift or
      // not — closes it. Inline mode reports a single date, so it never
      // starts one.
      if (_awaitingRangeEnd) {
        _secondSelected = date;
        _awaitingRangeEnd = false;
      } else if (!widget.singleDateMode &&
          !widget.inlineMode &&
          (startsRange || HardwareKeyboard.instance.isShiftPressed)) {
        _firstSelected = date;
        _secondSelected = null;
        _awaitingRangeEnd = true;
      } else {
        _firstSelected = date;
        _secondSelected = date;
      }
    });
    if (!_awaitingRangeEnd) _submit();
  }

  void _submitQuickAction(DateTime date) {
    setState(() {
      _firstSelected = date;
      _secondSelected = date;
    });
    _submit();
  }

  void _submit() {
    if (!mounted) return;
    DateTime start = _firstSelected ?? _hoveredDate;
    if (widget.inlineMode) {
      widget.onDateSelected?.call(start);
      return;
    }
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        DateTime end = _secondSelected ?? start;
        if (end.isBefore(start)) {
          final temp = start;
          start = end;
          end = temp;
        }
        Navigator.of(context).pop(DateTimeRange(start: start, end: end));
      }
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    final key = event.logicalKey;
    int dayDelta = 0;

    // The arrows move the highlighted day like h/j/k/l, so a day can be picked
    // without the mouse (BUG-111); the month turns when the day leaves it.
    // Enter — Ctrl+Enter included — picks the highlighted day.
    if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.arrowLeft) {
      dayDelta = -1;
    } else if (key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.arrowRight) {
      dayDelta = 1;
    } else if (key == LogicalKeyboardKey.keyJ ||
        key == LogicalKeyboardKey.arrowDown) {
      dayDelta = 7;
    } else if (key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.arrowUp) {
      dayDelta = -7;
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      setState(() {
        _showHoverRing = true;
      });
      _handleDateTap(_hoveredDate);
      return;
    }

    // The highlight stops at the range's edge.
    if (dayDelta != 0 &&
        _inRange(
          DateTime(
            _hoveredDate.year,
            _hoveredDate.month,
            _hoveredDate.day + dayDelta,
          ),
        )) {
      setState(() {
        _showHoverRing = true;
        _hoveredDate = DateTime(
          _hoveredDate.year,
          _hoveredDate.month,
          _hoveredDate.day + dayDelta,
        );
        if (_hoveredDate.year != _focusedMonth.year ||
            _hoveredDate.month != _focusedMonth.month) {
          _setFocusedMonth(DateTime(_hoveredDate.year, _hoveredDate.month, 1));
        }
      });
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isQuickChipSelected(DateTime chipDate) {
    if (_firstSelected == null) return false;
    final end = _secondSelected ?? _firstSelected!;
    if (!_isSameDay(_firstSelected!, end)) return false;
    return _isSameDay(_firstSelected!, chipDate);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    // The selected day and chip, made opaque the way the range highlight
    // below is: a translucent accent (Jobs' outline grey) let the popover
    // show through, and no label colour could be worked out against that.
    final selectedFill = Color.alphaBlend(accent, theme.colorScheme.surface);
    // Read off that fill: each page passes its own accent, and the theme's
    // onPrimary is made for the app accent, not this one (BUG-182).
    final onAccent = onColorLabel(
      selectedFill,
      themeInk: theme.colorScheme.onSurface,
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final chips = [
      {'label': 'Today', 'date': today},
      {
        'label': 'Tomorrow',
        'date': DateTime(today.year, today.month, today.day + 1),
      },
      {
        'label': 'Next Week',
        'date': DateTime(today.year, today.month, today.day + 7),
      },
    ];

    final weekStartsMonday =
        ref.watch(settingsProvider.settled).valueOrNull?.weekStartsOnMonday ??
        true;
    // Sunday first, rotated to Monday first when the grid starts there.
    final weekdayLabels = MaterialLocalizations.of(context).narrowWeekdays;
    final orderedWeekdayLabels = weekStartsMonday
        ? [...weekdayLabels.skip(1), weekdayLabels.first]
        : weekdayLabels;
    final startDate = calendarWeekStart(_focusedMonth, weekStartsMonday);

    DateTime? minDate;
    DateTime? maxDate;
    if (_firstSelected != null) {
      // Days only: an event ending at 10:00 on its last day would otherwise
      // count that day's midnight cell as inside the range, not its end.
      minDate = DateUtils.dateOnly(_firstSelected!);
      maxDate = DateUtils.dateOnly(_secondSelected ?? _firstSelected!);
      if (maxDate.isBefore(minDate)) {
        final temp = minDate;
        minDate = maxDate;
        maxDate = temp;
      }
    }

    // Days outside the month are greyed. Mid-scroll the month being left
    // dims to that grey while the one arriving brightens out of it, evenly
    // rather than on the scroll's ease-out, so the fade trails the motion.
    // Run off the controller, so a frame of it repaints the day numbers
    // without rebuilding their cells.
    Animation<double> ink(DateTime date) {
      final from = _inkFrom[DateTime(date.year, date.month)] ?? 0.3;
      final to =
          date.year == _focusedMonth.year && date.month == _focusedMonth.month
          ? 1.0
          : 0.3;
      return _scroll.drive(Tween(begin: from, end: to));
    }

    Widget dayCell(DateTime date, int column) {
      final isToday = _isSameDay(date, today);

      bool isSelected = false;
      bool isInRange = false;
      bool isRangeStart = false;
      bool isRangeEnd = false;

      if (minDate != null && maxDate != null) {
        if (_isSameDay(date, minDate)) {
          isSelected = true;
          isRangeStart = !_isSameDay(minDate, maxDate);
        }
        if (_isSameDay(date, maxDate)) {
          isSelected = true;
          isRangeEnd = !_isSameDay(minDate, maxDate);
        }
        if (date.isAfter(minDate) && date.isBefore(maxDate)) {
          isInRange = true;
        }
      }

      final isHovered = _isSameDay(date, _hoveredDate);

      final enabled = _inRange(date);
      Color textColor = theme.colorScheme.onSurface;
      if (isSelected) {
        textColor = onAccent;
      } else if (!enabled) {
        textColor = theme.colorScheme.onSurface.withValues(alpha: 0.25);
      }

      final highlightColor = Color.alphaBlend(
        accent.withValues(alpha: 0.7),
        theme.colorScheme.surface,
      );

      final bool isFirstDayOfWeek = column == 0;
      final bool isLastDayOfWeek = column == 6;

      return Center(
        child: SizedBox(
          height: 36,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // 1. Bridging Layer (Row with Expanded)
              if (isInRange || isRangeStart || isRangeEnd)
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Left Zone
                      Expanded(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // A range ending in the first column
                            // has nothing on its row to bridge to.
                            if ((isInRange ||
                                    (isRangeEnd && !isFirstDayOfWeek)) &&
                                !isRangeStart)
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left:
                                    0, // NEVER extend left! Prevents painting over previous cell
                                right: -1, // overlap center slightly
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: highlightColor,
                                    borderRadius: BorderRadius.only(
                                      topLeft: Radius.circular(
                                        isFirstDayOfWeek ? 100 : 0,
                                      ),
                                      bottomLeft: Radius.circular(
                                        isFirstDayOfWeek ? 100 : 0,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // Right Zone
                      Expanded(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Nor one starting in the last column.
                            if ((isInRange ||
                                    (isRangeStart && !isLastDayOfWeek)) &&
                                !isRangeEnd)
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: -1, // overlap center slightly
                                right: isLastDayOfWeek
                                    ? 0
                                    : -16, // Bridge securely to next cell
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: highlightColor,
                                    borderRadius: BorderRadius.only(
                                      topRight: Radius.circular(
                                        isLastDayOfWeek ? 100 : 0,
                                      ),
                                      bottomRight: Radius.circular(
                                        isLastDayOfWeek ? 100 : 0,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              // 2. Uniform Background for Translucent Circle
              if (isInRange || isRangeStart || isRangeEnd)
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: highlightColor,
                    shape: BoxShape.circle,
                  ),
                ),

              // 3. The actual day circle (Button & Text)
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isSelected ? selectedFill : Colors.transparent,
                  border: (isHovered && _showHoverRing)
                      ? Border.all(color: theme.colorScheme.onSurface, width: 2)
                      : null,
                  shape: BoxShape.circle,
                ),
                clipBehavior: Clip.antiAlias,
                child: Material(
                  color: Colors
                      .transparent, // Let Container handle the background color securely
                  child: InkWell(
                    onTap: enabled
                        ? () {
                            setState(() {
                              _showHoverRing = false;
                            });
                            _handleDateTap(date);
                          }
                        : null,
                    onLongPress: enabled
                        ? () {
                            setState(() {
                              _showHoverRing = false;
                            });
                            _handleDateTap(date, startsRange: true);
                          }
                        : null,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FadeTransition(
                            opacity: isSelected
                                ? kAlwaysCompleteAnimation
                                : ink(date),
                            child: Text(
                              '${date.day}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: textColor,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isToday && !isSelected)
                            Container(
                              width: 4,
                              height: 4,
                              margin: const EdgeInsets.only(top: 1),
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget content = Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        // Esc goes on to the popover's route, which closes without a pick
        // as a click outside does.
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        _handleKeyEvent(event);
        return KeyEventResult.handled;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // Zone A: Quick Actions
          // Not a scroller: the three chips fit the narrowest pane the
          // popover opens at (the date-and-time popover's left half), and a
          // horizontal scroller here slid them sideways under a stray
          // trackpad swipe. A [Wrap] rather than a [Row] so that a wider
          // label — or the fixed-pitch font a widget test renders with, which
          // is half again as wide — folds onto a second line instead of
          // overflowing.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: switch (widget.quickPickBuilder) {
              final builder? => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    for (final c in chips)
                      builder(
                        c['label'] as String,
                        _isQuickChipSelected(c['date'] as DateTime),
                        _inRange(c['date'] as DateTime)
                            ? () => _submitQuickAction(c['date'] as DateTime)
                            : null,
                      ),
                  ],
                ),
              ),
              null => Wrap(
                spacing: 6,
                runSpacing: 6,
                children: chips.map((c) {
                  final chipDate = c['date'] as DateTime;
                  final isSelected = _isQuickChipSelected(chipDate);
                  return ActionChip(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 0,
                    ),
                    // Half the default: the labels have to sit inside the
                    // pane at their natural width, unabbreviated.
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text(
                      c['label'] as String,
                      style: TextStyle(
                        color: isSelected
                            ? onAccent
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    backgroundColor: isSelected
                        ? selectedFill
                        : Colors.transparent,
                    side: isSelected
                        ? BorderSide(color: accent, width: 1)
                        : BorderSide(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.2,
                            ),
                            width: 1,
                          ),
                    onPressed: _inRange(chipDate)
                        ? () => _submitQuickAction(chipDate)
                        : null,
                  );
                }).toList(),
              ),
            },
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          // Zone B: The Micro-Grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.caretLeft, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: kMinTouchTarget,
                  onPressed: _previousMonth,
                ),
                // Shrinks rather than overflows where the title outgrows the
                // pane: "September 2026" does in the date-and-time popover's
                // left half under a large text scale, or in the fixed-pitch
                // font a widget test renders with.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      DateFormat.yMMMM().format(_focusedMonth),
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.caretRight, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: kMinTouchTarget,
                  onPressed: _nextMonth,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final label in orderedWeekdayLabels)
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
              // Six square week rows, cut from a strip of weeks that slides
              // up or down as the month turns. The strip spans the whole
              // scroll and is built once; a frame only moves it.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final rowHeight = constraints.maxWidth / 7;
                  final firstRow = min(_scrollFromWeeks.floor(), 0);
                  final lastRow = max(_scrollFromWeeks.ceil(), 0) + 5;
                  final strip = Column(
                    children: [
                      for (var row = firstRow; row <= lastRow; row++)
                        SizedBox(
                          // Keyed by week, so a row keeps its cells when a
                          // turn rebuilds the strip around it.
                          key: ValueKey(
                            DateTime(
                              startDate.year,
                              startDate.month,
                              startDate.day + row * 7,
                            ),
                          ),
                          height: rowHeight,
                          child: Row(
                            children: [
                              for (var column = 0; column < 7; column++)
                                Expanded(
                                  child: dayCell(
                                    DateTime(
                                      startDate.year,
                                      startDate.month,
                                      startDate.day + row * 7 + column,
                                    ),
                                    column,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  );
                  return Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      height: (rowHeight * 6).clamp(0, constraints.maxHeight),
                      child: ClipRect(
                        child: Stack(
                          children: [
                            AnimatedBuilder(
                              animation: _scroll,
                              child: strip,
                              builder: (context, strip) => Positioned(
                                top: (firstRow - _scrollWeeks) * rowHeight,
                                left: 0,
                                right: 0,
                                height: (lastRow - firstRow + 1) * rowHeight,
                                child: strip!,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );

    if (widget.inlineMode) return content;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (mounted) {
          setState(() => _canPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
      },
      child: content,
    );
  }
}

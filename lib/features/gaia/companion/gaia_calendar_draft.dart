import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_controls.dart';
import 'package:voyager/features/gaia/companion/gaia_date_picker.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// A draft of Gaia's own date picker, in place of Voyager's calendar inside
/// [showGaiaDatePicker]. It takes the same arguments and gives the same
/// pick, so it can stand in for it. The debug menu's only, for now.
Future<DateTimePick?> showGaiaCalendar(
  BuildContext context, {
  required DateTime initial,
  required bool timed,
  bool optionalTime = false,
  bool initialHasTime = true,
}) => showDialog<DateTimePick>(
  context: context,
  builder: (context) => GaiaDialog(
    // Its edge is a pixel each side.
    maxWidth: (timed ? _gridWidth + _timeWidth + 1 : _gridWidth) + 2,
    insetPadding: const EdgeInsets.all(12),
    content: GaiaCalendar(
      initial: initial,
      timed: timed,
      optionalTime: optionalTime,
      initialHasTime: initialHasTime,
      onPicked: (pick) => Navigator.of(context).pop(pick),
    ),
  ),
);

const _cell = Size(38, 34);
const _gridWidth = 38.0 * 7 + 2 * 14;
const _timeWidth = 196.0;

/// The weeks start on Monday: the companion has no settings to read
/// Voyager's choice from (GAIA_HLD.md §3.2), and Monday is its default.
const _weekdays = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

/// A month of days to pick one from, with Today, Tomorrow and Next week
/// under it. A click picks the day at once unless [timed]: then a time
/// column sits beside it and Done picks. Arrows move the day, Page Up and
/// Down the month, Home goes to today, and Enter picks; the wheel over the
/// days turns the month.
class GaiaCalendar extends StatefulWidget {
  const GaiaCalendar({
    super.key,
    required this.initial,
    required this.timed,
    required this.onPicked,
    this.optionalTime = false,
    this.initialHasTime = true,
  });

  final DateTime initial;
  final bool timed;

  /// With [timed], whether the time may be left off, as a task's can.
  final bool optionalTime;
  final bool initialHasTime;
  final ValueChanged<DateTimePick> onPicked;

  @override
  State<GaiaCalendar> createState() => _GaiaCalendarState();
}

class _GaiaCalendarState extends State<GaiaCalendar>
    with SingleTickerProviderStateMixin {
  late var _day = DateUtils.dateOnly(widget.initial);
  late var _month = DateTime(_day.year, _day.month);
  late var _time = TimeOfDay.fromDateTime(widget.initial);
  late var _hasTime =
      widget.timed && (!widget.optionalTime || widget.initialHasTime);

  /// The months lie side by side in a strip, and the view slides along it
  /// from the month at [_slideFrom] to [_month]: a month's index is its count
  /// of months since year 0, so the strip is continuous across years.
  late var _slideFrom = _indexOf(_month).toDouble();
  late final _slide = AnimationController(
    vsync: this,
    duration: GaiaMotion.move,
    value: 1,
  );

  static int _indexOf(DateTime month) => month.year * 12 + month.month - 1;
  static DateTime _monthAt(int index) => DateTime(index ~/ 12, index % 12 + 1);

  /// Where the view is in the strip, in months: between two while it slides.
  double get _shown =>
      _slideFrom +
      (_indexOf(_month) - _slideFrom) *
          GaiaMotion.travel.transform(_slide.value);

  /// Slides to [month] from wherever the view is, even mid-slide, so quick
  /// turns run on smoothly.
  void _showMonth(DateTime month) {
    if (month == _month) return;
    _slideFrom = _shown;
    _month = month;
    _slide.forward(from: 0);
  }

  final _focus = FocusNode();
  final _timeFocus = FocusNode();
  final _timeText = TextEditingController();

  @override
  void initState() {
    super.initState();
    _timeFocus.addListener(() {
      if (!_timeFocus.hasFocus) _readTime();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _showTime();
  }

  @override
  void dispose() {
    _slide.dispose();
    _focus.dispose();
    _timeFocus.dispose();
    _timeText.dispose();
    super.dispose();
  }

  DateTime get _today => DateUtils.dateOnly(DateTime.now());

  String _format(TimeOfDay time) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        time,
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  void _showTime() => _timeText.text = _format(_time);

  /// The field's text as a time, from "9", "930", "9:30", "9:30 pm" or
  /// "21:30"; back to the time it showed when it's none of those.
  void _readTime() {
    final match = RegExp(
      r'^\s*(\d{1,2})(?::?(\d{2}))?\s*([ap])?\.?\s*m?\.?\s*$',
      caseSensitive: false,
    ).firstMatch(_timeText.text);
    if (match != null) {
      var hour = int.parse(match[1]!);
      final minute = int.parse(match[2] ?? '0');
      final half = match[3]?.toLowerCase();
      if (half != null && hour >= 1 && hour <= 12) {
        hour = hour % 12 + (half == 'p' ? 12 : 0);
      }
      if (hour < 24 && minute < 60) {
        setState(() {
          _time = TimeOfDay(hour: hour, minute: minute);
          _hasTime = true;
        });
      }
    }
    _showTime();
  }

  void _setTime(TimeOfDay time) {
    setState(() {
      _time = time;
      _hasTime = true;
    });
    _showTime();
  }

  /// [minutes] on from the time (back when negative), round the clock,
  /// landing on a multiple of them.
  void _nudge(int minutes) {
    // From what's typed, when it's mid-edit.
    if (_timeFocus.hasFocus) _readTime();
    const day = 24 * 60;
    final step = minutes.abs();
    final now = _time.hour * 60 + _time.minute;
    final snapped = now ~/ step * step;
    final next = minutes > 0
        ? snapped + step
        : (snapped == now ? snapped - step : snapped);
    final total = (next % day + day) % day;
    _setTime(TimeOfDay(hour: total ~/ 60, minute: total % 60));
  }

  void _turn(int months) =>
      setState(() => _showMonth(DateTime(_month.year, _month.month + months)));

  void _select(DateTime day) {
    setState(() {
      _showMonth(DateTime(day.year, day.month));
      _day = day;
    });
  }

  /// A click on [day]: picked at once with no time to set, else selected.
  void _tap(DateTime day) {
    _select(day);
    if (widget.timed) {
      _focus.requestFocus();
    } else {
      _pick();
    }
  }

  void _pick() {
    if (_timeFocus.hasFocus) _readTime();
    widget.onPicked((
      dateTime: _hasTime
          ? DateTime(_day.year, _day.month, _day.day, _time.hour, _time.minute)
          : _day,
      hasTime: _hasTime,
    ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _pick();
      return KeyEventResult.handled;
    }
    // The time field keeps its own arrows.
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    DateTime move(int days) => DateTime(_day.year, _day.month, _day.day + days);
    // The same day of the month, or its last when it's shorter.
    DateTime moveMonths(int months) {
      final month = DateTime(_day.year, _day.month + months);
      final last = DateUtils.getDaysInMonth(month.year, month.month);
      return DateTime(month.year, month.month, _day.day.clamp(1, last));
    }

    final to = switch (key) {
      LogicalKeyboardKey.arrowLeft => move(-1),
      LogicalKeyboardKey.arrowRight => move(1),
      LogicalKeyboardKey.arrowUp => move(-7),
      LogicalKeyboardKey.arrowDown => move(7),
      LogicalKeyboardKey.pageUp => moveMonths(-1),
      LogicalKeyboardKey.pageDown => moveMonths(1),
      LogicalKeyboardKey.home => _today,
      _ => null,
    };
    if (to == null) return KeyEventResult.ignored;
    _select(to);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final days = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final name in _weekdays)
                SizedBox(
                  width: _cell.width,
                  child: Text(
                    name.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: GaiaType.heading,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _grid(),
          const SizedBox(height: 10),
          _quickPicks(),
        ],
      ),
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.timed
          ? IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: _gridWidth, child: days),
                  Container(width: 1, color: GaiaInk.hairline),
                  SizedBox(width: _timeWidth, child: _timeColumn()),
                ],
              ),
            )
          : SizedBox(width: _gridWidth, child: days),
    );
  }

  Widget _header() => Row(
    children: [
      const SizedBox(width: 6),
      Expanded(
        child: AnimatedSwitcher(
          duration: GaiaMotion.quick,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.centerLeft,
            children: [...previous, ?current],
          ),
          child: Text(
            DateFormat.yMMMM().format(_month),
            key: ValueKey(_month),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: GaiaInk.bright,
            ),
          ),
        ),
      ),
      GaiaButton(
        icon: Icons.chevron_left,
        size: 28,
        tooltip: 'Previous month (Page Up)',
        onPressed: () => _turn(-1),
      ),
      GaiaButton(
        icon: Icons.chevron_right,
        size: 28,
        tooltip: 'Next month (Page Down)',
        onPressed: () => _turn(1),
      ),
    ],
  );

  Widget _grid() {
    const width = 7 * 38.0;
    final today = _today;
    return Listener(
      // The wheel turns the month, a notch a month.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
          _turn(event.scrollDelta.dy > 0 ? 1 : -1);
        }
      },
      child: ClipRect(
        child: SizedBox(
          height: _cell.height * 6,
          child: AnimatedBuilder(
            animation: _slide,
            builder: (context, _) {
              // The one or two months in view, each where it lies in the
              // strip.
              final shown = _shown;
              final left = shown.floor();
              return Stack(
                children: [
                  for (final index in [left, if (shown > left) left + 1])
                    Positioned(
                      key: ValueKey(index),
                      left: (index - shown) * width,
                      top: 0,
                      width: width,
                      child: _weeks(_monthAt(index), today),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// [month]'s six weeks, from the Monday on or before its first.
  Widget _weeks(DateTime month, DateTime today) {
    final start = DateTime(
      month.year,
      month.month,
      1 - (month.weekday - DateTime.monday),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var week = 0; week < 6; week++)
          Row(
            children: [
              for (var weekday = 0; weekday < 7; weekday++)
                _cellFor(
                  DateTime(
                    start.year,
                    start.month,
                    start.day + week * 7 + weekday,
                  ),
                  month,
                  today,
                ),
            ],
          ),
      ],
    );
  }

  Widget _cellFor(DateTime day, DateTime month, DateTime today) => _DayCell(
    day: day,
    inMonth: day.month == month.month,
    today: day == today,
    selected: day == _day,
    onTap: () => _tap(day),
  );

  Widget _quickPicks() {
    final accent = Theme.of(context).colorScheme.primary;
    final today = _today;
    final picks = [
      ('Today', today),
      ('Tomorrow', DateTime(today.year, today.month, today.day + 1)),
      ('Next week', DateTime(today.year, today.month, today.day + 7)),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final (label, day) in picks)
          GaiaButton(
            label: label,
            size: 28,
            padding: 8,
            color: day == _day ? accent : null,
            onPressed: () => _tap(day),
          ),
      ],
    );
  }

  Widget _timeColumn() {
    final accent = Theme.of(context).colorScheme.primary;
    const presets = [
      TimeOfDay(hour: 9, minute: 0),
      TimeOfDay(hour: 12, minute: 0),
      TimeOfDay(hour: 15, minute: 0),
      TimeOfDay(hour: 18, minute: 0),
      TimeOfDay(hour: 21, minute: 0),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The pick as it stands, in words.
          Text(
            DateFormat('EEEE').format(_day),
            style: GaiaType.label.copyWith(color: GaiaInk.muted),
          ),
          const SizedBox(height: 2),
          Text(
            DateFormat('d MMMM y').format(_day),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: GaiaInk.bright,
            ),
          ),
          const SizedBox(height: 18),
          const Text('TIME', style: GaiaType.heading),
          const SizedBox(height: 8),
          AnimatedOpacity(
            duration: GaiaMotion.quick,
            opacity: _hasTime ? 1 : 0.4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    GaiaButton(
                      icon: Icons.remove,
                      size: 30,
                      tooltip: '15 minutes earlier',
                      onPressed: () => _nudge(-15),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Listener(
                        // The wheel over the time moves it 15 minutes a notch.
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent &&
                              event.scrollDelta.dy != 0) {
                            _nudge(event.scrollDelta.dy > 0 ? 15 : -15);
                          }
                        },
                        child: GaiaCardTextField(
                          controller: _timeText,
                          focusNode: _timeFocus,
                          style: GaiaType.row.copyWith(color: GaiaInk.bright),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GaiaButton(
                      icon: Icons.add,
                      size: 30,
                      tooltip: '15 minutes later',
                      onPressed: () => _nudge(15),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final preset in presets)
                      GaiaButton(
                        label: _format(preset),
                        size: 26,
                        padding: 8,
                        color: _hasTime && preset == _time ? accent : null,
                        onPressed: () => _setTime(preset),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.optionalTime) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                borderRadius: BorderRadius.circular(GaiaRadius.chip),
                onTap: () => setState(() => _hasTime = !_hasTime),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IgnorePointer(
                        child: GaiaCheckbox(
                          value: !_hasTime,
                          onChanged: (_) {},
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'No time',
                        style: GaiaType.row.copyWith(color: GaiaInk.dim),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: GaiaButton(
              label: 'Done',
              size: 32,
              color: accent,
              onPressed: _pick,
            ),
          ),
        ],
      ),
    );
  }
}

/// One day in the grid: lit on hover, the picked one filled and edged in
/// the accent, today edged alone, and the days either side of the month
/// faint.
class _DayCell extends StatefulWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  final DateTime day;
  final bool inMonth, today, selected;
  final VoidCallback onTap;

  @override
  State<_DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<_DayCell> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox.fromSize(
          size: _cell,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: AnimatedContainer(
              duration: GaiaMotion.quick,
              curve: GaiaMotion.curve,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? accent.withValues(alpha: 0.22)
                    : _hovered
                    ? GaiaInk.hover
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(GaiaRadius.row),
                border: Border.all(
                  color: selected
                      ? accent.withValues(alpha: 0.85)
                      : widget.today
                      ? accent.withValues(alpha: 0.45)
                      : Colors.transparent,
                ),
              ),
              child: Text(
                '${widget.day.day}',
                style: GaiaType.row.copyWith(
                  fontWeight: selected || widget.today
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: selected || _hovered
                      ? GaiaInk.bright
                      : widget.today
                      ? accent
                      : widget.inMonth
                      ? GaiaInk.dim
                      : GaiaInk.faint.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The debug menu's look at the draft: one open in place to hover over,
/// buttons for each way the chat opens a date picker, and the current one
/// beside them to compare.
class GaiaCalendarStudy extends StatefulWidget {
  const GaiaCalendarStudy({super.key});

  @override
  State<GaiaCalendarStudy> createState() => _GaiaCalendarStudyState();
}

class _GaiaCalendarStudyState extends State<GaiaCalendarStudy> {
  String? _last;

  void _show(DateTimePick? pick) {
    if (!mounted) return;
    setState(
      () => _last = pick == null
          ? 'Cancelled'
          : pick.hasTime
          ? DateFormat('EEE d MMM y, HH:mm').format(pick.dateTime)
          : '${DateFormat('EEE d MMM y').format(pick.dateTime)}, no time',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "A draft of Gaia's own calendar, not used by the chat yet. Arrows "
          'move the day, Page Up and Down the month, Home goes to today, '
          'Enter picks; the wheel over the days turns the month, and over the '
          'time moves it 15 minutes. The time field takes 9, 930, 9:30 pm or '
          '21:30.',
          style: muted,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            GaiaButton(
              label: 'Day',
              size: 32,
              onPressed: () async => _show(
                await showGaiaCalendar(context, initial: now, timed: false),
              ),
            ),
            GaiaButton(
              label: 'Day and time',
              size: 32,
              onPressed: () async => _show(
                await showGaiaCalendar(context, initial: now, timed: true),
              ),
            ),
            GaiaButton(
              label: 'Time optional',
              size: 32,
              onPressed: () async => _show(
                await showGaiaCalendar(
                  context,
                  initial: now,
                  timed: true,
                  optionalTime: true,
                  initialHasTime: false,
                ),
              ),
            ),
            GaiaButton(
              label: 'Current picker',
              size: 32,
              onPressed: () async => _show(
                await showGaiaDatePicker(
                  context,
                  initial: now,
                  timed: true,
                  optionalTime: true,
                ),
              ),
            ),
          ],
        ),
        if (_last case final last?) ...[
          const SizedBox(height: 8),
          Text('Picked: $last', style: muted),
        ],
        const SizedBox(height: 12),
        GaiaGlowRing(
          radius: GaiaRadius.panel,
          hovered: false,
          child: GaiaCalendar(initial: now, timed: false, onPicked: _show),
        ),
      ],
    );
  }
}

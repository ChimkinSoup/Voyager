import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/event_editor_dialog.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage>
    with TickerProviderStateMixin {
  CalendarViewMode _mode = CalendarViewMode.month;
  DateTime _focused = DateTime.now();
  DateTime? _dayViewDate;
  final _calendarAreaKey = GlobalKey();
  AnimationController? _monthZoomController;
  CurvedAnimation? _monthZoomAnimation;
  Rect? _monthZoomFromLocal;
  Rect? _monthZoomToLocal;
  DateTime? _monthZoomTarget;
  final _monthGridCache = _CalendarMonthGridCache();
  int? _prewarmingYear;
  int _prewarmGeneration = 0;
  ({
    List<CalendarEvent> events,
    List<CalendarDayIndicator> indicators,
    bool weekStartsMonday,
  })?
  _gridContext;

  Future<void> _openEditor({CalendarEvent? event, DateTime? day}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          EventEditorDialog(event: event, initialDate: day ?? _focused),
    );
    if (result == null || (result['title'] as String).isEmpty) return;

    final now = utcNow();
    final saved = CalendarEvent(
      id: event?.id ?? newId(),
      title: result['title'] as String,
      start: result['start'] as DateTime,
      end: result['end'] as DateTime,
      isFullDay: result['isFullDay'] as bool,
      colorValue: result['colorValue'] as int,
      notes: result['notes'] as String,
      source: event?.source ?? EventSource.local,
      externalId: event?.externalId,
      createdAt: event?.createdAt ?? now,
      updatedAt: now,
    );
    await ref.read(calendarRepositoryProvider).upsertEvent(saved);
    ref.invalidate(calendarEventsProvider);
  }

  Future<void> _syncGoogle() async {
    final service = ref.read(googleCalendarSyncProvider);
    await service.syncReadOnly(const []);
    ref.invalidate(calendarEventsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google Calendar sync complete (read-only)'),
        ),
      );
    }
  }

  void _shiftFocus(int delta) {
    setState(() {
      final base = _dayViewDate ?? _focused;
      if (_dayViewDate != null) {
        _dayViewDate = base.add(Duration(days: delta));
        _focused = DateTime(_dayViewDate!.year, _dayViewDate!.month, 1);
        return;
      }
      final nextFocused = switch (_mode) {
        CalendarViewMode.week => _focused.add(Duration(days: 7 * delta)),
        CalendarViewMode.month => DateTime(
          _focused.year,
          _focused.month + delta,
          1,
        ),
        CalendarViewMode.year => DateTime(_focused.year + delta, 1, 1),
      };
      if (_mode == CalendarViewMode.year && nextFocused.year != _focused.year) {
        _monthGridCache.clearExceptYear(nextFocused.year);
        _prewarmingYear = null;
      }
      _focused = nextFocused;
    });
  }

  void _onMiniCalendarDayTap(DateTime day) {
    _cancelMonthZoom();
    setState(() {
      if (_dayViewDate != null &&
          _dayViewDate!.year == day.year &&
          _dayViewDate!.month == day.month &&
          _dayViewDate!.day == day.day) {
        _dayViewDate = null;
      } else {
        _dayViewDate = DateTime(day.year, day.month, day.day);
        _focused = DateTime(day.year, day.month, 1);
      }
    });
  }

  String _headerLabel(bool weekStartsMonday) => switch (_mode) {
    CalendarViewMode.week =>
      'Week of ${DateFormat.MMMd().format(_weekStart(_focused, weekStartsMonday))}',
    CalendarViewMode.month => DateFormat.yMMMM().format(_focused),
    CalendarViewMode.year => '${_focused.year}',
  };

  @override
  void dispose() {
    _monthZoomController?.dispose();
    super.dispose();
  }

  void _cancelMonthZoom() {
    _monthZoomAnimation?.dispose();
    _monthZoomController?.dispose();
    _monthZoomController = null;
    _monthZoomAnimation = null;
    _monthZoomFromLocal = null;
    _monthZoomToLocal = null;
    _monthZoomTarget = null;
  }

  void _invalidateMonthGridCache() {
    _monthGridCache.clear();
    _prewarmingYear = null;
    _prewarmGeneration++;
  }

  bool get _isMonthZooming =>
      _monthZoomController != null &&
      _monthZoomAnimation != null &&
      _monthZoomFromLocal != null &&
      _monthZoomToLocal != null &&
      _monthZoomTarget != null;

  Widget _buildMonthGridLayer({
    required DateTime month,
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
    return RepaintBoundary(
      child: _buildCalendarGrid(
        events: events,
        indicators: indicators,
        weekStartsMonday: weekStartsMonday,
        mode: CalendarViewMode.month,
        focused: month,
        ignorePointer: true,
      ),
    );
  }

  void _scheduleMonthGridPrewarm({
    required int year,
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
    if (_prewarmingYear == year) return;

    _prewarmingYear = year;
    _monthGridCache.clearExceptYear(year);
    final generation = ++_prewarmGeneration;

    final months = _prewarmMonthOrder(year);
    void prewarmAt(int index) {
      if (!mounted || generation != _prewarmGeneration || _prewarmingYear != year) {
        return;
      }
      if (index >= months.length) return;

      final month = months[index];
      if (_monthGridCache.get(year, month) == null) {
        _monthGridCache.put(
          year,
          month,
          _buildMonthGridLayer(
            month: DateTime(year, month),
            events: events,
            indicators: indicators,
            weekStartsMonday: weekStartsMonday,
          ),
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        prewarmAt(index + 1);
      });
    }

    prewarmAt(0);
  }

  List<int> _prewarmMonthOrder(int year) {
    final now = DateTime.now();
    final prioritized = now.year == year ? now.month : _focused.month.clamp(1, 12);
    return [
      prioritized,
      for (var month = 1; month <= 12; month++)
        if (month != prioritized) month,
    ];
  }

  void _beginMonthZoom(DateTime month, Rect fromGlobal) {
    final stackContext = _calendarAreaKey.currentContext;
    if (stackContext == null) return;
    final stackBox = stackContext.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;

    _cancelMonthZoom();

    final stackOrigin = stackBox.localToGlobal(Offset.zero);
    final fromLocal = Rect.fromPoints(
      Offset(fromGlobal.left - stackOrigin.dx, fromGlobal.top - stackOrigin.dy),
      Offset(fromGlobal.right - stackOrigin.dx, fromGlobal.bottom - stackOrigin.dy),
    );
    final toLocal = Offset.zero & stackBox.size;

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    final animation = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
    );

    final context = _gridContext;

    _monthZoomController = controller;
    _monthZoomAnimation = animation;
    _monthZoomFromLocal = fromLocal;
    _monthZoomToLocal = toLocal;
    _monthZoomTarget = month;

    controller.forward().then((_) {
      if (!mounted) return;
      setState(() {
        _mode = CalendarViewMode.month;
        _focused = month;
        _dayViewDate = null;
        _cancelMonthZoom();
      });
    });

    setState(() {});

    if (context != null && !_monthGridCache.contains(month.year, month.month)) {
      final target = month;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _monthZoomTarget != target) return;
        final built = _buildMonthGridLayer(
          month: target,
          events: context.events,
          indicators: context.indicators,
          weekStartsMonday: context.weekStartsMonday,
        );
        _monthGridCache.put(target.year, target.month, built);
        setState(() {});
      });
    }
  }

  Widget _buildCalendarGrid({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
    required CalendarViewMode mode,
    required DateTime focused,
    bool ignorePointer = false,
  }) {
    final grid = CalendarGrid(
      mode: mode,
      focused: focused,
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
      onDayTap: (day) => _openEditor(day: day),
      onMonthTap: _beginMonthZoom,
    );
    if (!ignorePointer) return grid;
    return IgnorePointer(child: grid);
  }

  Widget _buildMainCalendar({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
    _gridContext = (
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
    );

    if (_dayViewDate != null) {
      return DayHourGrid(
        day: _dayViewDate!,
        events: events,
        onHourTap: (hour) => _openEditor(day: hour),
        onDayChanged: (day) => setState(() {
          _dayViewDate = day;
          _focused = DateTime(day.year, day.month, 1);
        }),
      );
    }

    if (_mode == CalendarViewMode.year || _isMonthZooming) {
      _scheduleMonthGridPrewarm(
        year: _focused.year,
        events: events,
        indicators: indicators,
        weekStartsMonday: weekStartsMonday,
      );

      final yearGrid = IgnorePointer(
        ignoring: _isMonthZooming,
        child: _buildCalendarGrid(
          events: events,
          indicators: indicators,
          weekStartsMonday: weekStartsMonday,
          mode: CalendarViewMode.year,
          focused: _focused,
        ),
      );

      if (!_isMonthZooming) {
        return yearGrid;
      }

      final zoomAnimation = _monthZoomAnimation!;
      final zoomMonth = _monthZoomTarget!;
      final cachedMonth = _monthGridCache.get(zoomMonth.year, zoomMonth.month);

      return AnimatedBuilder(
        animation: zoomAnimation,
        child: cachedMonth,
        builder: (context, monthLayer) {
          final progress = zoomAnimation.value;
          final overlayChild =
              monthLayer ??
              ColoredBox(color: Theme.of(context).colorScheme.surface);

          return Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: (1 - progress).clamp(0.0, 1.0),
                child: yearGrid,
              ),
              YearToMonthZoomOverlay(
                progress: progress,
                fromLocal: _monthZoomFromLocal!,
                toLocal: _monthZoomToLocal!,
                child: overlayChild,
              ),
            ],
          );
        },
      );
    }

    return _buildCalendarGrid(
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
      mode: _mode,
      focused: _focused,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<CalendarEvent>>>(calendarEventsProvider, (
      previous,
      next,
    ) {
      if (previous?.valueOrNull != next.valueOrNull) {
        _invalidateMonthGridCache();
      }
    });

    final eventsAsync = ref.watch(calendarEventsProvider);
    final trackers =
        ref.watch(trackersProvider).value ?? const <StatisticTracker>[];
    final analytics = ref.watch(analyticsServiceProvider);
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;
    final calendarTrackers = trackers
        .where((tracker) => tracker.showOnCalendar)
        .toList();
    final indicators = <CalendarDayIndicator>[];
    for (final tracker in calendarTrackers) {
      final values =
          ref.watch(trackerValuesProvider(tracker.id)).value ??
          const <TrackerValue>[];
      final max = values.fold<int>(0, (max, value) {
        final current = value.intValue ?? 0;
        return current > max ? current : max;
      });
      for (final value in values) {
        final intensity = analytics.heatmapIntensity(
          type: tracker.type,
          value: value,
          tracker: tracker,
          maxInPeriod: max == 0 ? 1 : max,
        );
        if (intensity <= 0) continue;
        indicators.add(
          CalendarDayIndicator(
            day: value.periodStart,
            colorValue: tracker.colorValue,
            label: '${tracker.name}: ${_trackerValueLabel(tracker, value)}',
            intensity: intensity,
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SegmentedButton<CalendarViewMode>(
                segments: const [
                  ButtonSegment(
                    value: CalendarViewMode.week,
                    label: Text('Week'),
                  ),
                  ButtonSegment(
                    value: CalendarViewMode.month,
                    label: Text('Month'),
                  ),
                  ButtonSegment(
                    value: CalendarViewMode.year,
                    label: Text('Year'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _cancelMonthZoom();
                  if (s.first != CalendarViewMode.year) {
                    _prewarmingYear = null;
                  }
                  _mode = s.first;
                  _dayViewDate = null;
                }),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _shiftFocus(-1),
                icon: const Icon(PhosphorIconsRegular.caretLeft),
              ),
              Text(_headerLabel(weekStartsMonday)),
              IconButton(
                onPressed: () => _shiftFocus(1),
                icon: const Icon(PhosphorIconsRegular.caretRight),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _syncGoogle,
                child: const Text('Sync Google'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _openEditor(day: _focused),
                child: const Text('Add event'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: eventsAsync.when(
              data: (events) => Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MiniMonthCalendar(
                    month: _focused,
                    weekStartsMonday: weekStartsMonday,
                    selectedDay: _dayViewDate,
                    onDayTap: _onMiniCalendarDayTap,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: KeyedSubtree(
                      key: _calendarAreaKey,
                      child: _buildMainCalendar(
                        events: events,
                        indicators: indicators,
                        weekStartsMonday: weekStartsMonday,
                      ),
                    ),
                  ),
                ],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

DateTime _weekStart(DateTime focused, bool weekStartsMonday) {
  final weekday = focused.weekday;
  final firstDay = weekStartsMonday ? DateTime.monday : DateTime.sunday;
  return DateTime(
    focused.year,
    focused.month,
    focused.day,
  ).subtract(Duration(days: (weekday - firstDay) % 7));
}

String _trackerValueLabel(StatisticTracker tracker, TrackerValue value) {
  return switch (tracker.type) {
    TrackerType.integer => '${value.intValue ?? tracker.defaultInt}',
    TrackerType.boolean =>
      (value.boolValue ?? tracker.defaultBool) ? 'yes' : 'no',
    TrackerType.enumType =>
      value.enumValue ?? tracker.defaultEnumOption ?? 'empty',
  };
}

/// Caches up to 12 pre-built month grids (one calendar year).
class _CalendarMonthGridCache {
  static const maxEntries = 12;

  final LinkedHashMap<String, Widget> _entries = LinkedHashMap();

  String _key(int year, int month) => '$year-$month';

  Widget? get(int year, int month) => _entries[_key(year, month)];

  bool contains(int year, int month) => _entries.containsKey(_key(year, month));

  void put(int year, int month, Widget grid) {
    final key = _key(year, month);
    _entries.remove(key);
    _entries[key] = grid;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clearExceptYear(int year) {
    final prefix = '$year-';
    _entries.removeWhere((key, _) => !key.startsWith(prefix));
  }

  void clear() => _entries.clear();
}

import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/event_editor_dialog.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage>
    with SingleTickerProviderStateMixin {
  CalendarViewMode _mode = CalendarViewMode.month;
  DateTime _focused = DateTime.now();
  DateTime? _dayViewDate;

  // One stable key per month tile in the year grid (for Matrix4 tween setup).
  final _monthTileKeys = List.generate(12, (_) => GlobalKey());
  // One stable key per tile's inner MonthDayGrid (for source-rect measurement).
  final _yearTileDayGridKeys = List.generate(12, (_) => GlobalKey());
  final _calendarAreaKey = GlobalKey();
  // Key for the full-size MonthDayGrid rendered during the measurement phase.
  final _fullMonthDayGridKey = GlobalKey();

  AnimationController? _zoomController;
  Matrix4Tween? _yearMatrixTween;
  bool _isZooming = false;
  // true when the animation is playing in the month→year direction.
  bool _morphReverse = false;

  // Morph state — populated just before the animation starts.
  List<Rect>? _morphSourceRects;
  List<Rect>? _morphDestRects;
  DateTime? _morphMonth;
  // Tile bounds (area-local) and area size captured at tap time — used to
  // position the morphing card background and month title overlay.
  Rect? _morphTileRect;
  Size? _morphAreaSize;
  // Snapshot taken at animation start so provider rebuilds don't interrupt ticks.
  List<CalendarEvent>? _morphEvents;
  List<CalendarDayIndicator>? _morphIndicators;
  List<CalendarEvent> _latestEvents = const [];
  List<CalendarDayIndicator> _latestIndicators = const [];
  int _morphGeneration = 0;
  AnimationStatusListener? _morphStatusListener;

  static const _zoomDuration = Duration(milliseconds: 600);

  AnimationController get _ensureZoomController {
    _zoomController ??=
        AnimationController(vsync: this, duration: _zoomDuration);
    return _zoomController!;
  }

  void _disposeMorphListener() {
    if (_morphStatusListener != null) {
      _zoomController?.removeStatusListener(_morphStatusListener!);
      _morphStatusListener = null;
    }
  }

  /// Invalidates in-flight morph callbacks and resets the shared controller.
  int _prepareMorphSession() {
    _morphGeneration++;
    _disposeMorphListener();
    _ensureZoomController
      ..stop()
      ..reset();
    return _morphGeneration;
  }

  void _abortMorphAnimation() {
    _prepareMorphSession();
  }

  void _clearMorphCache() {
    _morphSourceRects = null;
    _morphDestRects = null;
    _morphMonth = null;
    _morphTileRect = null;
    _morphAreaSize = null;
    _morphEvents = null;
    _morphIndicators = null;
  }

  void _startMorphAnimation({
    required int generation,
    required VoidCallback onComplete,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _morphGeneration) return;

      _disposeMorphListener();
      _morphStatusListener = (status) {
        if (status != AnimationStatus.completed) return;
        if (generation != _morphGeneration) return;
        _disposeMorphListener();
        if (!mounted) return;
        onComplete();
      };
      _ensureZoomController.addStatusListener(_morphStatusListener!);
      _ensureZoomController
        ..stop()
        ..reset()
        ..forward(from: 0);
    });
  }

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
    _abortMorphAnimation();
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      final base = _dayViewDate ?? _focused;
      if (_dayViewDate != null) {
        _dayViewDate = base.add(Duration(days: delta));
        _focused = DateTime(_dayViewDate!.year, _dayViewDate!.month, 1);
        return;
      }
      _focused = switch (_mode) {
        CalendarViewMode.week => _focused.add(Duration(days: 7 * delta)),
        CalendarViewMode.month => DateTime(
          _focused.year,
          _focused.month + delta,
          1,
        ),
        CalendarViewMode.year => DateTime(_focused.year + delta, 1, 1),
      };
    });
  }

  void _onMiniCalendarDayTap(DateTime day) {
    _abortMorphAnimation();
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      if (_dayViewDate != null &&
          _dayViewDate!.year == day.year &&
          _dayViewDate!.month == day.month &&
          _dayViewDate!.day == day.day) {
        _dayViewDate = null;
      } else {
        _dayViewDate = DateTime(day.year, day.month, day.day);
        _focused = DateTime(day.year, day.month, 1);
        _mode = CalendarViewMode.month;
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
    _disposeMorphListener();
    _zoomController?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Animation helpers
  // ---------------------------------------------------------------------------

  /// Computes 42 source [Rect]s (calendar-area-local) from the year tile's
  /// inner [MonthDayGrid].  Returns null if the render objects are not ready.
  List<Rect>? _computeSourceRects(DateTime month) {
    final areaBox =
        _calendarAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final gridBox = _yearTileDayGridKeys[month.month - 1]
        .currentContext
        ?.findRenderObject() as RenderBox?;

    if (areaBox == null || !areaBox.hasSize || !areaBox.attached) return null;
    if (gridBox == null || !gridBox.hasSize || !gridBox.attached) return null;

    final gridOrigin =
        areaBox.globalToLocal(gridBox.localToGlobal(Offset.zero));
    final cellW = gridBox.size.width / 7;
    final cellH = gridBox.size.height / 6;

    return List.generate(42, (i) => Rect.fromLTWH(
      gridOrigin.dx + (i % 7) * cellW,
      gridOrigin.dy + (i ~/ 7) * cellH,
      cellW,
      cellH,
    ));
  }

  /// Computes 42 destination [Rect]s from the [_fullMonthDayGridKey] widget
  /// that was laid out (but not painted) during the measurement phase.
  List<Rect>? _computeDestRects() {
    final areaBox =
        _calendarAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final gridBox =
        _fullMonthDayGridKey.currentContext?.findRenderObject() as RenderBox?;

    if (areaBox == null || !areaBox.hasSize) return null;
    if (gridBox == null || !gridBox.hasSize) return null;

    final gridOrigin =
        areaBox.globalToLocal(gridBox.localToGlobal(Offset.zero));
    final cellW = gridBox.size.width / 7;
    final cellH = gridBox.size.height / 6;

    return List.generate(42, (i) => Rect.fromLTWH(
      gridOrigin.dx + (i % 7) * cellW,
      gridOrigin.dy + (i ~/ 7) * cellH,
      cellW,
      cellH,
    ));
  }

  void _onMonthTapped(DateTime month) {
    if (_isZooming) return;

    final areaBox =
        _calendarAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (areaBox == null || !areaBox.hasSize || !areaBox.attached) return;

    final tileKey = _monthTileKeys[month.month - 1];
    final tileBox =
        tileKey.currentContext?.findRenderObject() as RenderBox?;
    if (tileBox == null || !tileBox.hasSize || !tileBox.attached) return;

    final tileOrigin =
        areaBox.globalToLocal(tileBox.localToGlobal(Offset.zero));
    final tileW = tileBox.size.width;
    final tileH = tileBox.size.height;
    final areaW = areaBox.size.width;
    final areaH = areaBox.size.height;

    // Scale so the tapped tile fills the entire area.
    final s = max(areaW / tileW, areaH / tileH);

    // Background layer: identity → scale-up/translate so the tile fills screen.
    _yearMatrixTween = Matrix4Tween(
      begin: Matrix4.identity(),
      end: Matrix4.identity()
        ..translateByDouble(-tileOrigin.dx * s, -tileOrigin.dy * s, 0, 1)
        ..scaleByDouble(s, s, 1, 1),
    );

    // Source rects must be computed now, while the year grid is still rendered.
    final sourceRects = _computeSourceRects(month);
    if (sourceRects == null) return;

    // Destination cell layout mirrors _MonthGrid — compute synchronously so we
    // can skip the offstage measurement frame that caused a visible stall.
    final titleStyle = Theme.of(context).textTheme.titleSmall!.copyWith(
      fontSize: MonthTitleHeader.titleFontSize,
    );
    final destRects = MonthTitleHeader.dayCellRects(
      Size(areaW, areaH),
      titleStyle,
    );

    final generation = _prepareMorphSession();

    // Capture tile and area geometry for the background/title overlay lerp.
    final morphTileRect =
        Rect.fromLTWH(tileOrigin.dx, tileOrigin.dy, tileW, tileH);
    final morphAreaSize = Size(areaW, areaH);

    setState(() {
      _focused = month;
      _dayViewDate = null;
      _isZooming = true;
      _morphReverse = false;
      _morphSourceRects = sourceRects;
      _morphDestRects = destRects;
      _morphMonth = month;
      _morphTileRect = morphTileRect;
      _morphAreaSize = morphAreaSize;
      _morphEvents = List<CalendarEvent>.from(_latestEvents);
      _morphIndicators = List<CalendarDayIndicator>.from(_latestIndicators);
    });

    _startMorphAnimation(
      generation: generation,
      onComplete: () => setState(() {
        _isZooming = false;
        _mode = CalendarViewMode.month;
        _clearMorphCache();
      }),
    );
  }

  void _onViewModeSelectionChanged(Set<CalendarViewMode> selection) {
    final next = selection.first;

    // Trigger the reverse zoom animation when switching month → year.
    if (next == CalendarViewMode.year &&
        _mode == CalendarViewMode.month &&
        !_isZooming &&
        _dayViewDate == null) {
      _onReverseToYear();
      return;
    }

    _abortMorphAnimation();
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _mode = next;
      _dayViewDate = null;
      if (next == CalendarViewMode.year) {
        _focused = DateTime(_focused.year, 1, 1);
      }
    });
  }

  /// Starts the reverse zoom animation (month → year).
  ///
  /// Mirrors [_onMonthTapped] exactly, but with source/dest roles swapped:
  ///   source (t=0) = full month-view cell positions
  ///   dest   (t=1) = year-tile cell positions
  /// The [Matrix4Tween] runs from zoomed-in → identity so the year grid flies
  /// back in rather than out.
  void _onReverseToYear() {
    final areaBox =
        _calendarAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (areaBox == null || !areaBox.hasSize || !areaBox.attached) {
      _immediatelySwitchToYear();
      return;
    }

    // Measure source rects right now — the month grid is live with
    // _fullMonthDayGridKey attached via the default _buildMainCalendar path.
    final sourceRects = _computeDestRects();
    if (sourceRects == null) {
      _immediatelySwitchToYear();
      return;
    }

    final generation = _prepareMorphSession();

    final areaW = areaBox.size.width;
    final areaH = areaBox.size.height;

    // Enter measurement phase: keep the month view visible while an Offstage
    // year grid renders so we can measure year-tile positions next frame.
    setState(() {
      _isZooming = true;
      _morphReverse = true;
      _morphSourceRects = sourceRects;
      _morphDestRects = null;
      _morphMonth = _focused;
      _morphTileRect = null;
      _morphAreaSize = Size(areaW, areaH);
      _morphEvents = List<CalendarEvent>.from(_latestEvents);
      _morphIndicators = List<CalendarDayIndicator>.from(_latestIndicators);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _morphGeneration) return;

      // Re-fetch areaBox — the reference captured before setState is detached
      // once the measurement-phase widget tree replaces the month view.
      final areaBox =
          _calendarAreaKey.currentContext?.findRenderObject() as RenderBox?;
      final destRects = _computeSourceRects(_focused);
      final tileKey = _monthTileKeys[_focused.month - 1];
      final tileBox =
          tileKey.currentContext?.findRenderObject() as RenderBox?;

      if (areaBox == null ||
          !areaBox.hasSize ||
          !areaBox.attached ||
          destRects == null ||
          tileBox == null ||
          !tileBox.hasSize ||
          !tileBox.attached) {
        setState(() => _isZooming = false);
        _immediatelySwitchToYear();
        return;
      }

      final areaW = areaBox.size.width;
      final areaH = areaBox.size.height;
      final tileOrigin =
          areaBox.globalToLocal(tileBox.localToGlobal(Offset.zero));
      final tileW = tileBox.size.width;
      final tileH = tileBox.size.height;
      final morphTileRect =
          Rect.fromLTWH(tileOrigin.dx, tileOrigin.dy, tileW, tileH);

      final s = max(areaW / tileW, areaH / tileH);

      // Reverse matrix: begin = tile fills screen, end = normal year grid.
      _yearMatrixTween = Matrix4Tween(
        begin: Matrix4.identity()
          ..translateByDouble(-tileOrigin.dx * s, -tileOrigin.dy * s, 0, 1)
          ..scaleByDouble(s, s, 1, 1),
        end: Matrix4.identity(),
      );

      // Reset before the animation-phase rebuild for the same reason as the
      // forward path: avoids a stale t=1 frame on first render.
      _ensureZoomController.reset();
      setState(() {
        _morphDestRects = destRects;
        _morphTileRect = morphTileRect;
      });

      _startMorphAnimation(
        generation: generation,
        onComplete: () => setState(() {
          _isZooming = false;
          _morphReverse = false;
          _mode = CalendarViewMode.year;
          _focused = DateTime(_focused.year, 1, 1);
          _clearMorphCache();
        }),
      );
    });
  }

  /// Falls back to an immediate view switch when measurement is unavailable.
  void _immediatelySwitchToYear() {
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _mode = CalendarViewMode.year;
      _focused = DateTime(_focused.year, 1, 1);
      _dayViewDate = null;
    });
  }

  void _instantSwitchToMonthView() {
    _abortMorphAnimation();
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _mode = CalendarViewMode.month;
      _dayViewDate = null;
    });
  }

  void _instantSwitchToYearView() {
    _abortMorphAnimation();
    _immediatelySwitchToYear();
  }

  // ---------------------------------------------------------------------------
  // Header / toolbar
  // ---------------------------------------------------------------------------

  Widget _buildFocusHeaderControls({
    required bool weekStartsMonday,
    required Widget label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () => _shiftFocus(-1),
          icon: const Icon(PhosphorIconsRegular.caretLeft),
        ),
        label,
        IconButton(
          onPressed: () => _shiftFocus(1),
          icon: const Icon(PhosphorIconsRegular.caretRight),
        ),
      ],
    );
  }

  Widget _buildViewModeSelector() {
    return _ViewModeSegmentedControl(
      weekSelect: _mode == CalendarViewMode.week ? 1 : 0,
      monthSelect: _mode == CalendarViewMode.month ? 1 : 0,
      yearSelect: _mode == CalendarViewMode.year ? 1 : 0,
      onSelectionChanged: _onViewModeSelectionChanged,
      interactive: !_isZooming,
    );
  }

  Widget _buildFocusHeader(BuildContext context, bool weekStartsMonday) {
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    return _buildFocusHeaderControls(
      weekStartsMonday: weekStartsMonday,
      label: Text(_headerLabel(weekStartsMonday), style: titleStyle),
    );
  }

  // ---------------------------------------------------------------------------
  // Calendar area
  // ---------------------------------------------------------------------------

  Widget _calendarGrid({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
    required CalendarViewMode mode,
    required DateTime focused,
    DateTime? hiddenMonth,
    GlobalKey? monthDayGridKey,
    bool monthNavigation = false,
  }) {
    return CalendarGrid(
      mode: mode,
      focused: focused,
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
      onDayTap: (day) => _openEditor(day: day),
      onMonthTap: _onMonthTapped,
      monthTileKeyBuilder: mode == CalendarViewMode.year
          ? (month) => _monthTileKeys[month.month - 1]
          : null,
      yearTileDayGridKeyBuilder: mode == CalendarViewMode.year
          ? (month) => _yearTileDayGridKeys[month.month - 1]
          : null,
      hiddenMonth: hiddenMonth,
      monthDayGridKey: monthDayGridKey,
      onPreviousMonth:
          monthNavigation ? () => _shiftFocus(-1) : null,
      onNextMonth: monthNavigation ? () => _shiftFocus(1) : null,
    );
  }

  Widget _buildMainCalendar({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
    final activeEvents = _morphEvents ?? events;
    final activeIndicators = _morphIndicators ?? indicators;

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

    // ---- Reverse measurement phase -------------------------------------------
    // Show the current month view (unchanged) while an Offstage year grid
    // renders so we can measure year-tile positions on the next frame.
    if (_isZooming && _morphReverse && _morphMonth != null && _morphDestRects == null) {
      final morphMonth = _morphMonth!;
      return IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _calendarGrid(
              events: activeEvents,
              indicators: activeIndicators,
              weekStartsMonday: weekStartsMonday,
              mode: CalendarViewMode.month,
              focused: morphMonth,
              monthNavigation: true,
            ),
            // Offstage year grid — laid out for measurement only.
            Offstage(
              offstage: true,
              child: _calendarGrid(
                events: activeEvents,
                indicators: activeIndicators,
                weekStartsMonday: weekStartsMonday,
                mode: CalendarViewMode.year,
                focused: DateTime(morphMonth.year, 1, 1),
              ),
            ),
          ],
        ),
      );
    }

    if (_isZooming &&
        _zoomController != null &&
        _yearMatrixTween != null &&
        _morphSourceRects != null &&
        _morphMonth != null &&
        _morphTileRect != null &&
        _morphAreaSize != null) {
      final morphMonth = _morphMonth!;
      final sourceRects = _morphSourceRects!;
      final yearTween = _yearMatrixTween!;
      final controller = _zoomController!;
      final tileRect = _morphTileRect!;
      final areaSize = _morphAreaSize!;

      if (_morphDestRects == null) {
        return const SizedBox.shrink();
      }

      return _MorphAnimationLayer(
        key: ValueKey(_morphGeneration),
        controller: controller,
        yearTween: yearTween,
        sourceRects: sourceRects,
        destRects: _morphDestRects!,
        morphReverse: _morphReverse,
        tileRect: tileRect,
        areaSize: areaSize,
        morphMonth: morphMonth,
        dates: monthGridDates(morphMonth, weekStartsMonday: weekStartsMonday),
        yearGrid: _calendarGrid(
          events: activeEvents,
          indicators: activeIndicators,
          weekStartsMonday: weekStartsMonday,
          mode: CalendarViewMode.year,
          focused: DateTime(morphMonth.year, 1, 1),
          hiddenMonth: morphMonth,
        ),
      );
    }

    return _calendarGrid(
      events: activeEvents,
      indicators: activeIndicators,
      weekStartsMonday: weekStartsMonday,
      mode: _mode,
      focused: _mode == CalendarViewMode.year
          ? DateTime(_focused.year, 1, 1)
          : _focused,
      // Keep the key attached to the live month grid so _computeDestRects()
      // can measure cell positions immediately when the reverse animation starts.
      monthDayGridKey: _mode == CalendarViewMode.month ? _fullMonthDayGridKey : null,
      monthNavigation: _mode == CalendarViewMode.month,
    );
  }

  List<CalendarDayIndicator> _buildCalendarIndicators(
    List<StatisticTracker> calendarTrackers,
    AnalyticsService analytics,
  ) {
    final indicators = <CalendarDayIndicator>[];
    for (final tracker in calendarTrackers) {
      final values =
          ref.watch(trackerValuesProvider(tracker.id)).value ??
          const <TrackerValue>[];
      final localMax = values.fold<int>(0, (m, value) {
        final current = value.intValue ?? 0;
        return current > m ? current : m;
      });
      for (final value in values) {
        final intensity = analytics.heatmapIntensity(
          type: tracker.type,
          value: value,
          tracker: tracker,
          maxInPeriod: localMax == 0 ? 1 : localMax,
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
    return indicators;
  }

  @override
  Widget build(BuildContext context) {
    final eventsAsync = ref.watch(calendarEventsProvider);
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;
    final showInstantViewSwitch =
        ref.watch(devSettingsProvider).showCalendarInstantViewSwitch;

    final List<CalendarDayIndicator> indicators;
    if (_isZooming && _morphIndicators != null) {
      indicators = _morphIndicators!;
    } else {
      final trackers =
          ref.watch(trackersProvider).value ?? const <StatisticTracker>[];
      final analytics = ref.watch(analyticsServiceProvider);
      final calendarTrackers = trackers
          .where((tracker) => tracker.showOnCalendar)
          .toList();
      indicators = _buildCalendarIndicators(calendarTrackers, analytics);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _buildViewModeSelector(),
              const Spacer(),
              if (_mode != CalendarViewMode.month && !_isZooming)
                _buildFocusHeader(context, weekStartsMonday),
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
              data: (events) {
                final calendarEvents =
                    _isZooming && _morphEvents != null ? _morphEvents! : events;
                if (!_isZooming) {
                  _latestEvents = events;
                  _latestIndicators = indicators;
                }
                return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 180,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: MiniMonthCalendar(
                            month: _focused,
                            weekStartsMonday: weekStartsMonday,
                            selectedDay: _dayViewDate,
                            onDayTap: _onMiniCalendarDayTap,
                          ),
                        ),
                        if (showInstantViewSwitch) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _instantSwitchToMonthView,
                            child: const Text('Month'),
                          ),
                          const SizedBox(height: 4),
                          OutlinedButton(
                            onPressed: _instantSwitchToYearView,
                            child: const Text('Year'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: KeyedSubtree(
                      key: _calendarAreaKey,
                      child: _buildMainCalendar(
                        events: calendarEvents,
                        indicators: indicators,
                        weekStartsMonday: weekStartsMonday,
                      ),
                    ),
                  ),
                ],
              );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Morph animation primitives
// =============================================================================

/// Provides the current morph progress [t] to descendant [_MorphCell]s without
/// recreating the cell widget list every tick.
class _MorphProgress extends InheritedWidget {
  const _MorphProgress({required this.t, required super.child});

  final double t;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MorphProgress>()!.t;

  @override
  bool updateShouldNotify(_MorphProgress old) => old.t != t;
}

/// Bifurcated morph stack — isolated from parent rebuilds during the animation.
class _MorphAnimationLayer extends StatefulWidget {
  const _MorphAnimationLayer({
    super.key,
    required this.controller,
    required this.yearTween,
    required this.sourceRects,
    required this.destRects,
    required this.morphReverse,
    required this.tileRect,
    required this.areaSize,
    required this.morphMonth,
    required this.dates,
    required this.yearGrid,
  });

  final AnimationController controller;
  final Matrix4Tween yearTween;
  final List<Rect> sourceRects;
  final List<Rect> destRects;
  final bool morphReverse;
  final Rect tileRect;
  final Size areaSize;
  final DateTime morphMonth;
  final List<DateTime> dates;
  final Widget yearGrid;

  @override
  State<_MorphAnimationLayer> createState() => _MorphAnimationLayerState();
}

class _MorphAnimationLayerState extends State<_MorphAnimationLayer> {
  static final _cardWidget = Card(
    margin: EdgeInsets.zero,
    child: SizedBox.expand(),
  );

  late final List<Widget> _cellChildren;
  late final Widget _yearGridChild;
  late final Matrix4 _yearMatrixBegin;
  late final Matrix4 _yearMatrixEnd;
  final _yearTransform = Matrix4.identity();
  late final Rect _fullAreaRect;
  late final Rect _sourceTitleRect;
  late final Rect _destTitleRect;

  @override
  void initState() {
    super.initState();
    _yearGridChild = widget.yearGrid;
    _yearMatrixBegin = Matrix4.copy(widget.yearTween.begin!);
    _yearMatrixEnd = Matrix4.copy(widget.yearTween.end!);
    _fullAreaRect =
        Rect.fromLTWH(0, 0, widget.areaSize.width, widget.areaSize.height);

    final tileCellRects =
        widget.morphReverse ? widget.destRects : widget.sourceRects;
    final monthCellRects =
        widget.morphReverse ? widget.sourceRects : widget.destRects;
    final tileHeaderTop = widget.tileRect.top + 8;
    _sourceTitleRect = Rect.fromLTWH(
      widget.tileRect.left + 8,
      tileHeaderTop,
      widget.tileRect.width - 16,
      (tileCellRects[0].top - tileHeaderTop - 4).clamp(4.0, double.infinity),
    );
    _destTitleRect = Rect.fromLTWH(
      8,
      8,
      widget.areaSize.width - 16,
      (monthCellRects[0].top - 12).clamp(8.0, double.infinity),
    );

    _cellChildren = [
      for (var i = 0; i < 42; i++)
        LayoutId(
          id: i,
          child: _MorphCell(
            key: ValueKey(widget.dates[i]),
            date: widget.dates[i],
            month: widget.morphMonth,
          ),
        ),
    ];
  }

  void _applyYearTransform(double t) {
    final out = _yearTransform.storage;
    final a = _yearMatrixBegin.storage;
    final b = _yearMatrixEnd.storage;
    for (var i = 0; i < 16; i++) {
      out[i] = a[i] + (b[i] - a[i]) * t;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: widget.controller,
          child: IgnorePointer(child: _yearGridChild),
          builder: (context, yearGridChild) {
            final t =
                Curves.easeInOutCubic.transform(widget.controller.value);
            final bgRect = widget.morphReverse
                ? Rect.lerp(_fullAreaRect, widget.tileRect, t)!
                : Rect.lerp(widget.tileRect, _fullAreaRect, t)!;
            final titleRect = widget.morphReverse
                ? Rect.lerp(_destTitleRect, _sourceTitleRect, t)!
                : Rect.lerp(_sourceTitleRect, _destTitleRect, t)!;
            final navOpacity = widget.morphReverse ? 1.0 - t : t;
            final navSpread = navOpacity;
            _applyYearTransform(t);

            return _MorphProgress(
              t: t,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Transform(
                    transform: _yearTransform,
                    child: yearGridChild,
                  ),
                  Positioned(
                    left: bgRect.left,
                    top: bgRect.top,
                    width: bgRect.width,
                    height: bgRect.height,
                    child: _cardWidget,
                  ),
                  CustomMultiChildLayout(
                    delegate: _MorphLayoutDelegate(
                      sourceRects: widget.sourceRects,
                      destRects: widget.destRects,
                      t: t,
                    ),
                    children: _cellChildren,
                  ),
                  Positioned(
                    left: titleRect.left,
                    top: titleRect.top,
                    width: titleRect.width,
                    height: titleRect.height,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: MonthTitleHeader(
                        month: widget.morphMonth,
                        navOpacity: navOpacity,
                        navSpread: navSpread,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Positions 42 children by lerping their bounds from [sourceRects] →
/// [destRects] as [t] goes from 0 → 1.
class _MorphLayoutDelegate extends MultiChildLayoutDelegate {
  _MorphLayoutDelegate({
    required this.sourceRects,
    required this.destRects,
    required this.t,
  });

  final List<Rect> sourceRects;
  final List<Rect> destRects;
  final double t;

  @override
  void performLayout(Size size) {
    for (var i = 0; i < 42; i++) {
      final rect = Rect.lerp(sourceRects[i], destRects[i], t)!;
      layoutChild(i, BoxConstraints.tight(rect.size));
      positionChild(i, rect.topLeft);
    }
  }

  @override
  bool shouldRelayout(_MorphLayoutDelegate old) => old.t != t;
}

/// A single calendar day cell that morphs between the compact year-tile style
/// (t = 0) and the full month-view style (t = 1).
///
/// Three properties are independently interpolated:
///   1. **Position + Size** — controlled by [_MorphLayoutDelegate] via Rect.lerp.
///   2. **Day number scale** — text is always rendered at the full font size and
///      scaled down with [Transform.scale], so it is always crisp.
///   3. **Border** — opacity lerped from 0 → 1 so it physically materialises.
class _MorphCell extends StatelessWidget {
  const _MorphCell({
    super.key,
    required this.date,
    required this.month,
  });

  final DateTime date;
  final DateTime month;

  // Compact year-tile font size → full month-view font size.
  static const _compactFontSize = 7.0;
  static const _fullFontSize = 15.0;
  static const _startScale = _compactFontSize / _fullFontSize;
  // Matches CalendarDayNumber's diameter formula: fontSize + (fontSize <= 9 ? 3 : 8).
  static const _diameter = _fullFontSize + 8.0;
  // Cell margin (creates the gap between adjacent cells).
  static const _compactCellMargin = 0.5; // compact.cellMargin.top
  static const _fullCellMargin = 1.0;    // full.cellMargin.top
  // Cell padding (inset inside the border, before the day number).
  static const _compactCellPadding = 1.0; // compact.cellPadding.top
  static const _fullCellPadding = 3.0;    // full.cellPadding.top

  @override
  Widget build(BuildContext context) {
    final t = _MorphProgress.of(context);
    // lerp(_startScale, 1.0, t)
    final textScale = _startScale + (1.0 - _startScale) * t;
    // Margin creates the gap between cells; padding offsets the number inside.
    // Splitting them matches the real CalendarDayCell layout at both endpoints.
    final cellMargin =
        _compactCellMargin + (_fullCellMargin - _compactCellMargin) * t;
    final cellPadding =
        _compactCellPadding + (_fullCellPadding - _compactCellPadding) * t;

    // lerp(compact.borderRadius, full.borderRadius, t)
    final borderRadius =
        MonthDayCellStyle.compact.borderRadius +
        (MonthDayCellStyle.full.borderRadius -
            MonthDayCellStyle.compact.borderRadius) *
        t;

    final dividerColor = Theme.of(context).dividerColor;

    return Container(
      // Margin creates the visible gap between adjacent cells.  The allocated
      // rect already includes this margin space, so shrinking inward here is
      // correct and matches the real CalendarDayCell behaviour.
      margin: EdgeInsets.all(cellMargin),
      decoration: BoxDecoration(
        border: Border.all(
          // Border opacity lerps 0 → 1 so it physically grows from nothing.
          color: dividerColor.withValues(alpha: t.clamp(0.0, 1.0)),
        ),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        // Top padding (inside the border) lerps from compact.cellPadding.top
        // to full.cellPadding.top, keeping the number's vertical position
        // aligned with the real CalendarDayCell at both endpoints.
        child: Padding(
          padding: EdgeInsets.only(top: cellPadding),
          child: Align(
            alignment: Alignment.topCenter,
              child: Transform.scale(
                scale: textScale,
                alignment: Alignment.topCenter,
                child: SizedBox.square(
                  dimension: _diameter,
                  child: CalendarDayNumber(
                    date: date,
                    month: month,
                    fontSize: _fullFontSize,
                    mutedWhenAdjacent: true,
                  ),
                ),
              ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// View-mode segmented control
// =============================================================================

class _ViewModeSegmentedControl extends StatelessWidget {
  const _ViewModeSegmentedControl({
    required this.weekSelect,
    required this.monthSelect,
    required this.yearSelect,
    required this.onSelectionChanged,
    this.interactive = true,
  });

  final double weekSelect;
  final double monthSelect;
  final double yearSelect;
  final ValueChanged<Set<CalendarViewMode>> onSelectionChanged;
  final bool interactive;

  static const _labels = ['Week', 'Month', 'Year'];

  double _selectFor(CalendarViewMode mode) {
    return switch (mode) {
      CalendarViewMode.week => weekSelect,
      CalendarViewMode.month => monthSelect,
      CalendarViewMode.year => yearSelect,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final buttonStyle = SegmentedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ).merge(theme.segmentedButtonTheme.style);
    final side =
        buttonStyle.side?.resolve(const {}) ??
        BorderSide(color: colorScheme.outline);
    final padding =
        buttonStyle.padding?.resolve(const {}) ??
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    final minSize =
        buttonStyle.minimumSize?.resolve(const {}) ?? const Size(48, 40);
    final textStyle =
        buttonStyle.textStyle?.resolve(const {}) ??
        theme.textTheme.labelLarge;
    const outerRadius = Radius.circular(18);

    final selectedBackground = colorScheme.primary;
    const unselectedBackground = Colors.transparent;
    final selectedForeground = colorScheme.onPrimary;
    final unselectedForeground = colorScheme.onSurface;

    Widget segment(int index, CalendarViewMode mode) {
      final selectProgress = _selectFor(mode).clamp(0.0, 1.0);
      final background = Color.lerp(
        unselectedBackground,
        selectedBackground,
        selectProgress,
      )!;
      final foreground = Color.lerp(
        unselectedForeground,
        selectedForeground,
        selectProgress,
      )!;

      BorderRadius borderRadius;
      if (index == 0) {
        borderRadius = const BorderRadius.horizontal(left: outerRadius);
      } else if (index == _labels.length - 1) {
        borderRadius = const BorderRadius.horizontal(right: outerRadius);
      } else {
        borderRadius = BorderRadius.zero;
      }

      final child = DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: borderRadius,
        ),
        child: Padding(
          padding: padding,
          child: Text(
            _labels[index],
            style: textStyle?.copyWith(color: foreground),
          ),
        ),
      );

      if (!interactive) {
        return child;
      }

      return InkWell(
        onTap: () => onSelectionChanged({mode}),
        borderRadius: borderRadius,
        splashFactory: NoSplash.splashFactory,
        child: child,
      );
    }

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < _labels.length; index++)
          segment(index, CalendarViewMode.values[index]),
      ],
    );

    final control = SizedBox(
      height: minSize.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.fromBorderSide(side),
          borderRadius: BorderRadius.circular(outerRadius.x),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(outerRadius.x),
          child: Align(alignment: Alignment.center, child: row),
        ),
      ),
    );

    if (!interactive) {
      return IgnorePointer(child: control);
    }

    return control;
  }
}

// =============================================================================
// Utilities
// =============================================================================

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

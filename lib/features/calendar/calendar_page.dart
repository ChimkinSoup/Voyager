import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/cache_status.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/event_editor_dialog.dart';
import 'package:voyager/features/calendar/month_zoom_prewarm_tracker.dart';

enum _MonthZoomDirection { zoomIn, zoomOut }

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
  final _dayCellKeys = <String, GlobalKey>{};
  final _probeDayCellKeys = <String, GlobalKey>{};

  AnimationController? _monthZoomController;
  Map<DateTime, Rect>? _monthZoomFromRects;
  Map<DateTime, Rect>? _monthZoomToRects;
  DateTime? _monthZoomTarget;
  _MonthZoomDirection _monthZoomDirection = _MonthZoomDirection.zoomIn;

  static const _monthZoomPreFadeDuration = Duration(milliseconds: 100);
  static const _monthZoomMorphDuration = Duration(milliseconds: 400);
  static const _monthZoomYearSegmentFadeDuration = Duration(milliseconds: 100);
  static const _monthZoomMonthSegmentFadeDuration = Duration(milliseconds: 400);
  static const _monthZoomDuration = Duration(
    milliseconds: 500,
  ); // pre-fade + morph

  double _zoomEasedProgress(double elapsedMs, Duration duration) {
    return Curves.easeInCubic.transform(
      (elapsedMs / duration.inMilliseconds).clamp(0.0, 1.0),
    );
  }

  double _headerMonthReveal(double linear) {
    final morph = _headerMorphPhase(linear);
    return Curves.easeOutCubic.transform(morph);
  }

  double _headerMonthOpacity(double linear) {
    final morph = _headerMorphPhase(linear);
    return Curves.easeOut.transform(morph);
  }

  List<Rect>? _monthZoomSlotRects;
  Size? _monthZoomSlotAreaSize;
  bool? _monthZoomSlotWeekStartsMonday;
  bool? _monthZoomSlotRectsFromProbe;
  bool _probeMeasureScheduled = false;
  bool _prewarmReportScheduled = false;
  bool _morphPipelineWarmed = false;
  bool _morphWarmupMounted = false;
  Map<DateTime, Rect>? _morphWarmupLocalRects;
  DateTime? _morphWarmupMonth;
  AnimationController? _yearViewMonthZoomController;

  ({
    List<CalendarEvent> events,
    List<CalendarDayIndicator> indicators,
    bool weekStartsMonday,
  })?
  _gridContext;

  GlobalKey _dayCellKeyFor(DateTime ownerMonth, DateTime cellDate) {
    final id =
        '${ownerMonth.year}-${ownerMonth.month}-'
        '${cellDate.year}-${cellDate.month}-${cellDate.day}';
    return _dayCellKeys.putIfAbsent(id, GlobalKey.new);
  }

  GlobalKey _probeDayCellKeyFor(DateTime cellDate) {
    final id =
        'probe-${cellDate.year}-${cellDate.month}-${cellDate.day}';
    return _probeDayCellKeys.putIfAbsent(id, GlobalKey.new);
  }

  MonthZoomPrewarmTracker get _monthZoomPrewarmTracker =>
      ref.read(monthZoomPrewarmTrackerProvider);

  void _invalidateMonthZoomSlotCache() {
    _monthZoomSlotRects = null;
    _monthZoomSlotAreaSize = null;
    _monthZoomSlotWeekStartsMonday = null;
    _monthZoomSlotRectsFromProbe = null;
    _resetMorphPipelineWarmup();
  }

  void _resetMorphPipelineWarmup() {
    _morphPipelineWarmed = false;
    _morphWarmupMounted = false;
    _morphWarmupLocalRects = null;
    _morphWarmupMonth = null;
  }

  void _disposeYearViewMonthZoomController() {
    _yearViewMonthZoomController?.dispose();
    _yearViewMonthZoomController = null;
  }

  void _ensureYearViewMonthZoomController() {
    _yearViewMonthZoomController ??= AnimationController(
      vsync: this,
      duration: _monthZoomDuration,
    );
  }

  void _refreshMorphWarmupTargets({
    required BuildContext areaContext,
    required RenderBox areaBox,
    required bool weekStartsMonday,
  }) {
    final month = DateTime(_focused.year, 6, 1);
    final rects = _monthZoomTargetsFor(
      areaContext,
      areaBox,
      month,
      weekStartsMonday,
    );
    if (rects.isEmpty) return;

    _morphWarmupMonth = month;
    _morphWarmupLocalRects = rects;
    if (!_morphPipelineWarmed && !_morphWarmupMounted) {
      _scheduleMorphPipelineWarmup();
    }
  }

  void _scheduleMorphPipelineWarmup() {
    if (_morphPipelineWarmed ||
        _morphWarmupMounted ||
        _morphWarmupLocalRects == null) {
      return;
    }

    setState(() => _morphWarmupMounted = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _morphWarmupMounted = false;
        _morphPipelineWarmed = true;
      });
    });
  }

  Widget _buildMorphWarmupOverlay({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
    if (!_morphWarmupMounted ||
        _morphWarmupLocalRects == null ||
        _morphWarmupMonth == null) {
      return const SizedBox.shrink();
    }

    return RepaintBoundary(
      child: IgnorePointer(
        child: Opacity(
          opacity: 0,
          child: MonthZoomMorphOverlay(
            progress: 0,
            month: _morphWarmupMonth!,
            fromLocalRects: _morphWarmupLocalRects!,
            toLocalRects: _morphWarmupLocalRects!,
            events: events,
            indicators: indicators,
            weekStartsMonday: weekStartsMonday,
          ),
        ),
      ),
    );
  }

  int _countYearGridSourceCells(DateTime monthDate, bool weekStartsMonday) {
    var count = 0;
    for (final date in monthGridDates(
      monthDate,
      weekStartsMonday: weekStartsMonday,
    )) {
      final key = _dayCellKeyFor(monthDate, date);
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        count++;
      }
    }
    return count;
  }

  void _reportPrewarmStatus({
    required bool eventsLoaded,
    required bool weekStartsMonday,
  }) {
    final areaContext = _calendarAreaKey.currentContext;
    final areaBox = areaContext?.findRenderObject() as RenderBox?;
    final areaReady = areaBox != null && areaBox.hasSize;
    final areaSize = areaBox?.size;

    final yearViewActive =
        _mode == CalendarViewMode.year &&
        _dayViewDate == null &&
        !_isMonthZooming;

    final slotsCached =
        _monthZoomSlotRects != null &&
        areaSize != null &&
        _monthZoomSlotAreaSize == areaSize &&
        _monthZoomSlotWeekStartsMonday == weekStartsMonday;

    final slotsMeasured =
        _monthZoomSlotRectsFromProbe == true &&
        (_monthZoomSlotRects?.length ?? 0) == 42;

    final probeIdle = !_probeMeasureScheduled;

    final sampleMonth = DateTime(_focused.year, _focused.month, 1);
    final sourceCellCount = yearViewActive
        ? _countYearGridSourceCells(sampleMonth, weekStartsMonday)
        : 0;
    final sourceCellsReady = sourceCellCount == 42;

    final CacheItemStatus layoutCacheStatus;
    if (!yearViewActive) {
      layoutCacheStatus = const CacheItemStatus(
        label: 'Calendar zoom layout',
        state: CacheItemState.notStarted,
        detail: 'Not in year view',
      );
    } else if (_probeMeasureScheduled) {
      layoutCacheStatus = const CacheItemStatus(
        label: 'Calendar zoom layout',
        state: CacheItemState.loading,
        detail: 'Measuring probe grid',
      );
    } else if (!slotsCached) {
      layoutCacheStatus = const CacheItemStatus(
        label: 'Calendar zoom layout',
        state: CacheItemState.notStarted,
        detail: 'Waiting for slot cache',
      );
    } else if (slotsMeasured) {
      layoutCacheStatus = const CacheItemStatus(
        label: 'Calendar zoom layout',
        state: CacheItemState.loaded,
        detail: 'Measured (42 slots from probe)',
      );
    } else {
      layoutCacheStatus = CacheItemStatus(
        label: 'Calendar zoom layout',
        state: CacheItemState.loaded,
        detail: 'Computed fallback (${_monthZoomSlotRects!.length} slots)',
      );
    }

    final checks = <MonthZoomPrewarmCheck>[
      MonthZoomPrewarmCheck(
        label: 'Year view active',
        passed: yearViewActive,
      ),
      MonthZoomPrewarmCheck(
        label: 'Calendar events loaded',
        passed: eventsLoaded,
      ),
      MonthZoomPrewarmCheck(
        label: 'Calendar area sized',
        passed: areaReady,
      ),
      MonthZoomPrewarmCheck(
        label: 'Probe measurement idle',
        passed: yearViewActive && probeIdle,
        detail: probeIdle ? null : 'Post-frame measure scheduled',
      ),
      MonthZoomPrewarmCheck(
        label: 'Target slot layout cached',
        passed: slotsCached,
      ),
      MonthZoomPrewarmCheck(
        label: 'Target slots measured (42)',
        passed: slotsMeasured,
      ),
      MonthZoomPrewarmCheck(
        label: 'Year grid source cells (${sampleMonth.month})',
        passed: yearViewActive && sourceCellsReady,
        detail: sourceCellsReady ? null : '$sourceCellCount/42 cells laid out',
      ),
    ];

    final passedCount = checks.where((check) => check.passed).length;
    final isFullyPrewarmed = yearViewActive && passedCount == checks.length;
    final summary = isFullyPrewarmed
        ? 'Fully pre-warmed'
        : yearViewActive
        ? '$passedCount/${checks.length} checks passed'
        : 'Open Calendar in year view';

    _monthZoomPrewarmTracker.update(
      MonthZoomPrewarmStatus(
        checks: checks,
        isFullyPrewarmed: isFullyPrewarmed,
        summary: summary,
        layoutCacheStatus: layoutCacheStatus,
      ),
    );
  }

  void _schedulePrewarmStatusReport({required bool weekStartsMonday}) {
    if (_prewarmReportScheduled) return;
    _prewarmReportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prewarmReportScheduled = false;
      if (!mounted) return;
      _reportPrewarmStatus(
        eventsLoaded: ref.read(calendarEventsProvider).hasValue,
        weekStartsMonday: weekStartsMonday,
      );
    });
  }

  List<Rect> _monthZoomSlotRectsFor({
    required BuildContext areaContext,
    required RenderBox areaBox,
    required bool weekStartsMonday,
  }) {
    final areaSize = areaBox.size;
    if (_monthZoomSlotRects != null &&
        _monthZoomSlotAreaSize == areaSize &&
        _monthZoomSlotWeekStartsMonday == weekStartsMonday) {
      return _monthZoomSlotRects!;
    }

    final probeMonth = DateTime(_focused.year, 6, 1);
    final measured = MonthDayGridLayout.readSlotRectsFromKeys(
      month: probeMonth,
      weekStartsMonday: weekStartsMonday,
      dayCellKeyBuilder: _probeDayCellKeyFor,
      areaBox: areaBox,
    );
    if (measured.length == 42) {
      _monthZoomSlotRects = measured;
      _monthZoomSlotRectsFromProbe = true;
    } else {
      final headerHeight = MonthDayGridLayout.measureWeekdayHeaderHeight(
        areaContext,
        weekStartsMonday: weekStartsMonday,
      );
      _monthZoomSlotRects = MonthDayGridLayout.computeSlotRects(
        areaSize: areaSize,
        weekdayHeaderHeight: headerHeight,
      );
      _monthZoomSlotRectsFromProbe = false;
    }

    _monthZoomSlotAreaSize = areaSize;
    _monthZoomSlotWeekStartsMonday = weekStartsMonday;
    return _monthZoomSlotRects!;
  }

  void _scheduleProbeSlotMeasure(bool weekStartsMonday) {
    if (_probeMeasureScheduled) return;
    _probeMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeMeasureScheduled = false;
      if (!mounted || _mode != CalendarViewMode.year || _isMonthZooming) return;

      final areaContext = _calendarAreaKey.currentContext;
      final areaBox = areaContext?.findRenderObject() as RenderBox?;
      if (areaContext == null || areaBox == null || !areaBox.hasSize) return;

      _monthZoomSlotRectsFor(
        areaContext: areaContext,
        areaBox: areaBox,
        weekStartsMonday: weekStartsMonday,
      );
      _refreshMorphWarmupTargets(
        areaContext: areaContext,
        areaBox: areaBox,
        weekStartsMonday: weekStartsMonday,
      );
      _ensureYearViewMonthZoomController();
      _reportPrewarmStatus(
        eventsLoaded: ref.read(calendarEventsProvider).hasValue,
        weekStartsMonday: weekStartsMonday,
      );
    });
  }

  Widget _buildMonthLayoutProbe({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
    return IgnorePointer(
      child: Opacity(
        opacity: 0,
        child: MonthDayGrid(
          month: DateTime(_focused.year, 6, 1),
          events: events,
          indicators: indicators,
          weekStartsMonday: weekStartsMonday,
          style: MonthDayCellStyle.full,
          showWeekdayHeader: true,
          dayCellKeyBuilder: _probeDayCellKeyFor,
        ),
      ),
    );
  }

  void _trimDayCellKeys() {
    while (_dayCellKeys.length > 504) {
      _dayCellKeys.remove(_dayCellKeys.keys.first);
    }
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
    setState(() {
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
    _cancelMonthZoom();
    _disposeYearViewMonthZoomController();
    final tracker = _monthZoomPrewarmTracker;
    Future<void>(() => tracker.markIdle());
    super.dispose();
  }

  void _cancelMonthZoom() {
    _monthZoomController?.dispose();
    _monthZoomController = null;
    _monthZoomFromRects = null;
    _monthZoomToRects = null;
    _monthZoomTarget = null;
    _monthZoomDirection = _MonthZoomDirection.zoomIn;
  }

  bool get _isMonthZooming =>
      _monthZoomController != null &&
      _monthZoomFromRects != null &&
      _monthZoomToRects != null &&
      _monthZoomTarget != null;

  Map<DateTime, Rect> _collectDayGlobalRects({
    required DateTime ownerMonth,
    required bool weekStartsMonday,
  }) {
    final rects = <DateTime, Rect>{};
    for (final date in monthGridDates(
      ownerMonth,
      weekStartsMonday: weekStartsMonday,
    )) {
      final key = _dayCellKeyFor(ownerMonth, date);
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        rects[date] = box.localToGlobal(Offset.zero) & box.size;
      }
    }
    return rects;
  }

  Map<DateTime, Rect>? _globalRectsToLocal(
    Map<DateTime, Rect> globalRects,
    RenderBox areaBox,
  ) {
    if (!areaBox.attached || !areaBox.hasSize) return null;
    final stackOrigin = areaBox.localToGlobal(Offset.zero);
    return {
      for (final entry in globalRects.entries)
        entry.key: entry.value.shift(-stackOrigin),
    };
  }

  ({double nonTransitionOpacity, double morphProgress}) _monthZoomFrame(
    double linear,
  ) {
    final elapsedMs = linear * _monthZoomDuration.inMilliseconds;
    final preFadeMs = _monthZoomPreFadeDuration.inMilliseconds;
    final morphMs = _monthZoomMorphDuration.inMilliseconds;

    if (_monthZoomDirection == _MonthZoomDirection.zoomOut) {
      if (elapsedMs <= morphMs) {
        final morphLinear = (elapsedMs / morphMs).clamp(0.0, 1.0);
        return (
          nonTransitionOpacity: 0.0,
          morphProgress: Curves.easeInCubic.transform(morphLinear),
        );
      }

      final postFadeT = _zoomEasedProgress(
        elapsedMs - morphMs,
        _monthZoomPreFadeDuration,
      );
      return (nonTransitionOpacity: postFadeT, morphProgress: 1.0);
    }

    if (elapsedMs <= preFadeMs) {
      final preFadeT = _zoomEasedProgress(elapsedMs, _monthZoomPreFadeDuration);
      return (nonTransitionOpacity: 1.0 - preFadeT, morphProgress: 0.0);
    }

    final morphLinear =
        ((elapsedMs - preFadeMs) / morphMs).clamp(0.0, 1.0);
    return (
      nonTransitionOpacity: 0.0,
      morphProgress: Curves.easeInCubic.transform(morphLinear),
    );
  }

  double _headerMorphPhase(double linear) {
    final elapsedMs = linear * _monthZoomDuration.inMilliseconds;
    if (_monthZoomDirection == _MonthZoomDirection.zoomOut) {
      return (elapsedMs / _monthZoomMorphDuration.inMilliseconds)
          .clamp(0.0, 1.0);
    }
    if (elapsedMs <= _monthZoomPreFadeDuration.inMilliseconds) return 0;
    return ((elapsedMs - _monthZoomPreFadeDuration.inMilliseconds) /
            _monthZoomMorphDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  double _headerMonthRevealForZoom(double linear) {
    final morph = _headerMorphPhase(linear);
    if (_monthZoomDirection == _MonthZoomDirection.zoomOut) {
      return Curves.easeOutCubic.transform(1.0 - morph);
    }
    return _headerMonthReveal(linear);
  }

  double _headerMonthOpacityForZoom(double linear) {
    final morph = _headerMorphPhase(linear);
    if (_monthZoomDirection == _MonthZoomDirection.zoomOut) {
      return Curves.easeOut.transform(1.0 - morph);
    }
    return _headerMonthOpacity(linear);
  }

  Widget _buildMonthYearLabel({
    required BuildContext context,
    required String monthName,
    required String yearLabel,
    required double monthReveal,
    required double monthOpacity,
  }) {
    final titleStyle = Theme.of(context).textTheme.titleMedium;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (monthReveal > 0)
          ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: monthReveal.clamp(0.0, 1.0),
              child: Opacity(
                opacity: monthOpacity.clamp(0.0, 1.0),
                child: Text('$monthName ', style: titleStyle),
              ),
            ),
          ),
        Text(yearLabel, style: titleStyle),
      ],
    );
  }

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

  void _onViewModeSelectionChanged(Set<CalendarViewMode> selection) {
    final next = selection.first;
    if (next == CalendarViewMode.year &&
        _mode == CalendarViewMode.month &&
        !_isMonthZooming) {
      _beginMonthZoomOut();
      return;
    }

    setState(() {
      _cancelMonthZoom();
      _disposeYearViewMonthZoomController();
      _invalidateMonthZoomSlotCache();
      _mode = next;
      _dayViewDate = null;
    });
  }

  ({
    double weekSelect,
    double monthSelect,
    double yearSelect,
  }) _viewModeSegmentSelect(double linear) {
    if (_isMonthZooming) {
      final elapsedMs = linear * _monthZoomDuration.inMilliseconds;
      if (_monthZoomDirection == _MonthZoomDirection.zoomOut) {
        final morphMs = _monthZoomMorphDuration.inMilliseconds;
        return (
          weekSelect: 0,
          monthSelect: 1 -
              _zoomEasedProgress(
                elapsedMs,
                _monthZoomMonthSegmentFadeDuration,
              ),
          yearSelect: elapsedMs >= morphMs
              ? _zoomEasedProgress(
                  elapsedMs - morphMs,
                  _monthZoomYearSegmentFadeDuration,
                )
              : 0,
        );
      }

      return (
        weekSelect: 0,
        monthSelect: _zoomEasedProgress(
          elapsedMs,
          _monthZoomMonthSegmentFadeDuration,
        ),
        yearSelect: 1 -
            _zoomEasedProgress(
              elapsedMs,
              _monthZoomYearSegmentFadeDuration,
            ),
      );
    }

    return (
      weekSelect: _mode == CalendarViewMode.week ? 1 : 0,
      monthSelect: _mode == CalendarViewMode.month ? 1 : 0,
      yearSelect: _mode == CalendarViewMode.year ? 1 : 0,
    );
  }

  Widget _buildViewModeSelector() {
    final controller = _monthZoomController;
    if (_isMonthZooming && controller != null) {
      return AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final select = _viewModeSegmentSelect(controller.value);
          return _ViewModeSegmentedControl(
            weekSelect: select.weekSelect,
            monthSelect: select.monthSelect,
            yearSelect: select.yearSelect,
            onSelectionChanged: _onViewModeSelectionChanged,
            interactive: false,
          );
        },
      );
    }

    final select = _viewModeSegmentSelect(0);
    return _ViewModeSegmentedControl(
      weekSelect: select.weekSelect,
      monthSelect: select.monthSelect,
      yearSelect: select.yearSelect,
      onSelectionChanged: _onViewModeSelectionChanged,
    );
  }

  Widget _buildFocusHeader(BuildContext context, bool weekStartsMonday) {
    if (_mode == CalendarViewMode.week) {
      return _buildFocusHeaderControls(
        weekStartsMonday: weekStartsMonday,
        label: Text(
          _headerLabel(weekStartsMonday),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    if (_isMonthZooming && _monthZoomTarget != null) {
      final month = _monthZoomTarget!;
      final monthName = DateFormat.MMMM().format(month);
      final yearLabel = '${month.year}';

      final controller = _monthZoomController;
      if (controller != null) {
        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final linear = controller.value;
            return _buildFocusHeaderControls(
              weekStartsMonday: weekStartsMonday,
              label: _buildMonthYearLabel(
                context: context,
                monthName: monthName,
                yearLabel: yearLabel,
                monthReveal: _headerMonthRevealForZoom(linear),
                monthOpacity: _headerMonthOpacityForZoom(linear),
              ),
            );
          },
        );
      }

      return _buildFocusHeaderControls(
        weekStartsMonday: weekStartsMonday,
        label: _buildMonthYearLabel(
          context: context,
          monthName: monthName,
          yearLabel: yearLabel,
          monthReveal: 1,
          monthOpacity: 1,
        ),
      );
    }

    if (_mode == CalendarViewMode.month) {
      return _buildFocusHeaderControls(
        weekStartsMonday: weekStartsMonday,
        label: _buildMonthYearLabel(
          context: context,
          monthName: DateFormat.MMMM().format(_focused),
          yearLabel: '${_focused.year}',
          monthReveal: 1,
          monthOpacity: 1,
        ),
      );
    }

    return _buildFocusHeaderControls(
      weekStartsMonday: weekStartsMonday,
      label: Text(
        _headerLabel(weekStartsMonday),
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  void _startMonthZoomAnimation({
    required DateTime month,
    required Map<DateTime, Rect> fromLocal,
    required Map<DateTime, Rect> toLocal,
    required _MonthZoomDirection direction,
  }) {
    final controller =
        _yearViewMonthZoomController ??
        AnimationController(
          vsync: this,
          duration: _monthZoomDuration,
        );
    _yearViewMonthZoomController = null;
    controller
      ..stop()
      ..reset();

    void onZoomCompleted(AnimationStatus status) {
      if (status != AnimationStatus.completed) return;
      controller.removeStatusListener(onZoomCompleted);
      if (!mounted) return;
      if (_monthZoomDirection == _MonthZoomDirection.zoomOut) {
        final weekStartsMonday =
            _gridContext?.weekStartsMonday ??
            ref.read(settingsProvider).value?.weekStartsOnMonday ??
            true;
        setState(() {
          _mode = CalendarViewMode.year;
          _focused = DateTime(month.year, 1, 1);
          _dayViewDate = null;
          _cancelMonthZoom();
        });
        _scheduleProbeSlotMeasure(weekStartsMonday);
        return;
      }
      setState(_cancelMonthZoom);
    }

    controller.addStatusListener(onZoomCompleted);

    _monthZoomController = controller;
    _monthZoomFromRects = fromLocal;
    _monthZoomToRects = toLocal;
    _monthZoomTarget = month;
    _monthZoomDirection = direction;

    setState(() {
      if (direction == _MonthZoomDirection.zoomIn) {
        _mode = CalendarViewMode.month;
        _focused = month;
        _dayViewDate = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _monthZoomController != controller) return;
      controller.forward(from: 0);
    });
  }

  void _beginMonthZoomOut() {
    final areaContext = _calendarAreaKey.currentContext;
    if (areaContext == null) return;
    final areaBox = areaContext.findRenderObject() as RenderBox?;
    if (areaBox == null || !areaBox.hasSize || !areaBox.attached) return;

    _cancelMonthZoom();
    _disposeYearViewMonthZoomController();

    final weekStartsMonday =
        _gridContext?.weekStartsMonday ??
        ref.read(settingsProvider).value?.weekStartsOnMonday ??
        true;

    final globalFrom = _collectDayGlobalRects(
      ownerMonth: _focused,
      weekStartsMonday: weekStartsMonday,
    );
    if (globalFrom.isEmpty) {
      setState(() {
        _mode = CalendarViewMode.year;
        _focused = DateTime(_focused.year, 1, 1);
        _dayViewDate = null;
      });
      return;
    }

    final fromLocal = _globalRectsToLocal(globalFrom, areaBox);
    if (fromLocal == null) {
      setState(() {
        _mode = CalendarViewMode.year;
        _focused = DateTime(_focused.year, 1, 1);
        _dayViewDate = null;
      });
      return;
    }

    final titleHeight = YearMonthTileLayout.measureMonthTitleHeight(areaContext);
    final toLocal = YearMonthTileLayout.computeDayRects(
      areaSize: areaBox.size,
      month: _focused,
      weekStartsMonday: weekStartsMonday,
      monthTitleHeight: titleHeight,
    );
    if (toLocal.length < 42) {
      setState(() {
        _mode = CalendarViewMode.year;
        _focused = DateTime(_focused.year, 1, 1);
        _dayViewDate = null;
      });
      return;
    }

    _startMonthZoomAnimation(
      month: _focused,
      fromLocal: fromLocal,
      toLocal: toLocal,
      direction: _MonthZoomDirection.zoomOut,
    );
  }

  Map<DateTime, Rect> _monthZoomTargetsFor(
    BuildContext areaContext,
    RenderBox areaBox,
    DateTime month,
    bool weekStartsMonday,
  ) {
    final slots = _monthZoomSlotRectsFor(
      areaContext: areaContext,
      areaBox: areaBox,
      weekStartsMonday: weekStartsMonday,
    );
    return MonthDayGridLayout.mapDatesToSlotRects(
      month: month,
      weekStartsMonday: weekStartsMonday,
      slotRects: slots,
    );
  }

  void _beginMonthZoom(
    DateTime month,
    Map<DateTime, Rect> dayGlobalRects,
  ) {
    final areaContext = _calendarAreaKey.currentContext;
    if (areaContext == null) return;
    final areaBox = areaContext.findRenderObject() as RenderBox?;
    if (areaBox == null || !areaBox.hasSize) return;

    _cancelMonthZoom();

    final stackOrigin = areaBox.localToGlobal(Offset.zero);
    final fromLocal = <DateTime, Rect>{};
    for (final entry in dayGlobalRects.entries) {
      fromLocal[entry.key] = entry.value.shift(-stackOrigin);
    }

    if (fromLocal.isEmpty) {
      setState(() {
        _mode = CalendarViewMode.month;
        _focused = month;
        _dayViewDate = null;
      });
      return;
    }

    final weekStartsMonday =
        _gridContext?.weekStartsMonday ??
        ref.read(settingsProvider).value?.weekStartsOnMonday ??
        true;

    final toLocal = _monthZoomTargetsFor(
      areaContext,
      areaBox,
      month,
      weekStartsMonday,
    );

    _startMonthZoomAnimation(
      month: month,
      fromLocal: fromLocal,
      toLocal: toLocal,
      direction: _MonthZoomDirection.zoomIn,
    );
  }

  Widget _buildCalendarGrid({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
    required CalendarViewMode mode,
    required DateTime focused,
    bool ignorePointer = false,
    DateTime? zoomSourceMonth,
    double nonTransitionOpacity = 1,
    bool hideZoomSourceDayCells = false,
    bool fadeNonSourceMonthsOnly = false,
  }) {
    _trimDayCellKeys();
    final grid = CalendarGrid(
      mode: mode,
      focused: focused,
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
      onDayTap: (day) => _openEditor(day: day),
      onMonthTap: _beginMonthZoom,
      dayCellKeyBuilder: _dayCellKeyFor,
      zoomSourceMonth: zoomSourceMonth,
      nonTransitionOpacity: nonTransitionOpacity,
      hideZoomSourceDayCells: hideZoomSourceDayCells,
      fadeNonSourceMonthsOnly: fadeNonSourceMonthsOnly,
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

    if (_isMonthZooming || _mode == CalendarViewMode.year) {
      if (_mode == CalendarViewMode.year && !_isMonthZooming) {
        _scheduleProbeSlotMeasure(weekStartsMonday);
      }

      if (_isMonthZooming) {
        final controller = _monthZoomController!;
        final zoomMonth = _monthZoomTarget!;
        final zoomOut = _monthZoomDirection == _MonthZoomDirection.zoomOut;

        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final linear = controller.value;
            final frame = _monthZoomFrame(linear);
            final chromeOpacity = frame.nonTransitionOpacity.clamp(0.0, 1.0);
            // Zoom-out: month grid OR morph — never both (avoids double image).
            final showMonthUnderlay = zoomOut && frame.morphProgress <= 0;
            final showMorph = !zoomOut || frame.morphProgress > 0;

            return Stack(
              fit: StackFit.expand,
              children: [
                if (showMonthUnderlay)
                  IgnorePointer(
                    child: _buildCalendarGrid(
                      events: events,
                      indicators: indicators,
                      weekStartsMonday: weekStartsMonday,
                      mode: CalendarViewMode.month,
                      focused: zoomMonth,
                    ),
                  ),
                if (chromeOpacity > 0)
                  IgnorePointer(
                    child: _buildCalendarGrid(
                      events: events,
                      indicators: indicators,
                      weekStartsMonday: weekStartsMonday,
                      mode: CalendarViewMode.year,
                      focused: DateTime(zoomMonth.year, 1, 1),
                      zoomSourceMonth: zoomMonth,
                      nonTransitionOpacity: chromeOpacity,
                      hideZoomSourceDayCells: true,
                      fadeNonSourceMonthsOnly: zoomOut,
                    ),
                  ),
                if (showMorph)
                  Material(
                    color: Colors.transparent,
                    child: MonthZoomMorphOverlay(
                      progress: frame.morphProgress,
                      month: zoomMonth,
                      fromLocalRects: _monthZoomFromRects!,
                      toLocalRects: _monthZoomToRects!,
                      events: events,
                      indicators: indicators,
                      weekStartsMonday: weekStartsMonday,
                      zoomOut: zoomOut,
                    ),
                  ),
              ],
            );
          },
        );
      }

      final yearGrid = _buildCalendarGrid(
        events: events,
        indicators: indicators,
        weekStartsMonday: weekStartsMonday,
        mode: CalendarViewMode.year,
        focused: DateTime(_focused.year, 1, 1),
      );

      final probe = _buildMonthLayoutProbe(
        events: events,
        indicators: indicators,
        weekStartsMonday: weekStartsMonday,
      );

      return Stack(
        fit: StackFit.expand,
        children: [
          yearGrid,
          probe,
          _buildMorphWarmupOverlay(
            events: events,
            indicators: indicators,
            weekStartsMonday: weekStartsMonday,
          ),
        ],
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
        _dayCellKeys.clear();
        _probeDayCellKeys.clear();
        _invalidateMonthZoomSlotCache();
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

    _schedulePrewarmStatusReport(weekStartsMonday: weekStartsMonday);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _buildViewModeSelector(),
              const Spacer(),
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

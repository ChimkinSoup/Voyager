import 'dart:math' show max;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/calendar_keyboard_shortcuts.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

/// Shared [DateFormat] instance — avoids repeated allocation on every build.
final _mmmmFormat = DateFormat.MMMM();

enum _CalendarSidebarKind { none, event, todo }

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

  _CalendarSidebarKind _sidebarKind = _CalendarSidebarKind.none;
  CalendarEvent? _sidebarEvent;
  DateTime? _sidebarEventInitialDate;
  TodoTask? _sidebarTodo;

  final _calendarAreaKey = GlobalKey();

  late final AnimationController _zoomController;
  late final ScrollController _weekTimelineScrollController;
  double _weekTimelineScrollOffset = calendarWeekDefaultScrollOffset();
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
  List<CalendarTodoMarker>? _morphTodos;
  List<CalendarEvent> _latestEvents = const [];
  List<CalendarDayIndicator> _latestIndicators = const [];
  List<CalendarTodoMarker> _latestTodos = const [];
  int _morphGeneration = 0;
  AnimationStatusListener? _morphStatusListener;

  // Pre-computed morph geometry — populated on the first [LayoutBuilder] pass
  // (year or month view) and refreshed on resize. All tap handlers read from
  // here; no render-object measurement at animation time.
  CalendarLayoutCache? _layoutCache;

  // Month ↔ week morph state.
  late final AnimationController _weekMorphController;

  bool _isWeekMorphing = false;
  bool _weekMorphForward = true;
  int _weekMorphWeekRow = 0;
  DateTime? _weekMorphAnchor;
  DateTime? _lastViewedMonth;
  DateTime? _lastViewedWeekStart;
  int _weekMorphGeneration = 0;
  AnimationStatusListener? _weekMorphStatusListener;
  List<CalendarEvent>? _weekMorphEvents;
  List<CalendarDayIndicator>? _weekMorphIndicators;
  List<CalendarTodoMarker>? _weekMorphTodos;

  static const _sidebarWidth = 350.0;
  static const _zoomDuration = Duration(milliseconds: 6000);
  static const _weekMorphDuration = Duration(milliseconds: 6000);
  static const _chainedMorphDuration = Duration(milliseconds: 4000);

  bool _isChainedWeekToYear = false;
  bool _isChainedYearToWeek = false;

  @override
  void initState() {
    super.initState();
    _zoomController = AnimationController(vsync: this, duration: _zoomDuration);
    _weekMorphController = AnimationController(
      vsync: this,
      duration: _weekMorphDuration,
    );
    final maxWeekScroll = calendarWeekTimelineScrollContentHeight();
    _weekTimelineScrollOffset =
        calendarWeekDefaultScrollOffset().clamp(0.0, maxWeekScroll);
    _weekTimelineScrollController = ScrollController(
      initialScrollOffset: _weekTimelineScrollOffset,
    );
    _weekTimelineScrollController.addListener(_onWeekTimelineScrolled);
    final now = DateTime.now();
    _lastViewedMonth = DateTime(now.year, now.month, 1);
  }

  void _disposeMorphListener() {
    if (_morphStatusListener != null) {
      _zoomController.removeStatusListener(_morphStatusListener!);
      _morphStatusListener = null;
    }
  }

  /// Invalidates in-flight morph callbacks and resets the shared controller.
  int _prepareMorphSession() {
    _morphGeneration++;
    _disposeMorphListener();
    _zoomController
      ..stop()
      ..reset();
    return _morphGeneration;
  }

  void _abortMorphAnimation() {
    _isChainedWeekToYear = false;
    _isChainedYearToWeek = false;
    _weekMorphController.duration = _weekMorphDuration;
    _zoomController.duration = _zoomDuration;
    _prepareMorphSession();
    _prepareWeekMorphSession();
  }

  void _disposeWeekMorphListener() {
    if (_weekMorphStatusListener != null) {
      _weekMorphController.removeStatusListener(_weekMorphStatusListener!);
      _weekMorphStatusListener = null;
    }
  }

  int _prepareWeekMorphSession({bool resetValue = true}) {
    _weekMorphGeneration++;
    _disposeWeekMorphListener();
    _weekMorphController.stop();
    if (resetValue) {
      _weekMorphController.value = 0;
    }
    return _weekMorphGeneration;
  }

  void _clearWeekMorphCache() {
    _weekMorphEvents = null;
    _weekMorphIndicators = null;
    _weekMorphTodos = null;
    _weekMorphAnchor = null;
  }

  /// Month grid month to restore when leaving week view (latest month in the
  /// currently focused week when it spans a month boundary).
  DateTime _visibleMonthForWeekReturn(bool weekStartsMonday) {
    return _latestMonthInWeek(_focused, weekStartsMonday);
  }

  DateTime _latestMonthInWeek(DateTime weekAnchor, bool weekStartsMonday) {
    final weekStart = _weekStart(weekAnchor, weekStartsMonday);
    var latest = DateTime(weekStart.year, weekStart.month);
    for (var i = 1; i < 7; i++) {
      final day = weekStart.add(Duration(days: i));
      final candidate = DateTime(day.year, day.month);
      if (candidate.isAfter(latest)) {
        latest = candidate;
      }
    }
    return DateTime(latest.year, latest.month, 1);
  }

  void _rememberViewedMonth(DateTime month) {
    _lastViewedMonth = DateTime(month.year, month.month, 1);
  }

  void _rememberViewedWeek(DateTime date, bool weekStartsMonday) {
    final start = _weekStart(date, weekStartsMonday);
    _lastViewedWeekStart = DateTime(start.year, start.month, start.day);
  }

  /// Month to open when zooming from year view via the segment control.
  DateTime _monthTargetForYear(int year) {
    final saved = _lastViewedMonth;
    if (saved != null && saved.year == year) {
      return saved;
    }
    final now = DateTime.now();
    if (year == now.year) {
      return DateTime(year, now.month, 1);
    }
    return DateTime(year, 1, 1);
  }

  void _startWeekMorphAnimation({
    required int generation,
    required bool reverse,
    required VoidCallback onComplete,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _weekMorphGeneration) return;

      _disposeWeekMorphListener();
      void onStatus(AnimationStatus status) {
        final done = reverse
            ? status == AnimationStatus.dismissed
            : status == AnimationStatus.completed;
        if (!done) return;
        if (generation != _weekMorphGeneration) return;
        _disposeWeekMorphListener();
        if (!mounted) return;
        onComplete();
      }

      _weekMorphStatusListener = onStatus;
      _weekMorphController.addStatusListener(_weekMorphStatusListener!);
      if (reverse) {
        _weekMorphController
          ..value = 1.0
          ..reverse(from: 1.0);
      } else {
        _weekMorphController.forward(from: 0);
      }
    });
  }

  void _clearMorphCache() {
    _morphSourceRects = null;
    _morphDestRects = null;
    _morphMonth = null;
    _morphTileRect = null;
    _morphAreaSize = null;
    _morphEvents = null;
    _morphIndicators = null;
    _morphTodos = null;
  }

  /// Recomputes [_layoutCache] when [areaSize] changes.
  ///
  /// Called from the calendar [LayoutBuilder] on the first layout pass (and on
  /// resize). Pure math — no widget mounting, no frame waits, no render-object
  /// reads. Safe to call synchronously from layout and tap handlers.
  void _refreshLayoutCache(Size areaSize) {
    if (_layoutCache?.areaSize == areaSize) return;

    final (compact, full) = _weekdayMorphStyles(context);
    final (yearName, monthTitle) = _titleMorphStyles(context);
    final weekdayStyle = calendarWeekdayLabelStyle(
      context,
      fontSize: calendarWeekWeekdayFontSize,
    );
    _layoutCache = CalendarLayoutCache.compute(
      areaSize: areaSize,
      yearTileNameStyle: yearName,
      compactWeekdayStyle: compact,
      fullTitleStyle: monthTitle,
      fullWeekdayStyle: full,
      weekWeekdayStyle: weekdayStyle,
    );
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
      _zoomController.addStatusListener(_morphStatusListener!);
      _zoomController
        ..stop()
        ..reset()
        ..forward(from: 0);
    });
  }

  void _openEventSidebar({CalendarEvent? event, DateTime? day}) {
    setState(() {
      _sidebarKind = _CalendarSidebarKind.event;
      _sidebarEvent = event;
      _sidebarEventInitialDate = day ?? _focused;
      _sidebarTodo = null;
    });
  }

  Future<void> _openTodoSidebar(CalendarTodoMarker marker) async {
    final tasks = await ref.read(allTodoTasksProvider.future);
    final matches = tasks.where((t) => t.id == marker.taskId);
    if (matches.isEmpty || !mounted) return;
    final task = matches.first;
    setState(() {
      _sidebarKind = _CalendarSidebarKind.todo;
      _sidebarTodo = task;
      _sidebarEvent = null;
    });
  }

  void _openWeekSlotSidebar(DateTime day, DateTime time) {
    _openEventSidebar(day: time);
  }

  void _handleEntryTap(CalendarDayEntry entry) {
    if (entry.isTodo) {
      _openTodoSidebar(entry.todo!);
      return;
    }
    _openEventSidebar(event: entry.event);
  }

  void _closeSidebar() {
    setState(() {
      _sidebarKind = _CalendarSidebarKind.none;
      _sidebarEvent = null;
      _sidebarEventInitialDate = null;
      _sidebarTodo = null;
    });
  }

  Future<void> _saveSidebarEvent(Map<String, dynamic> result) async {
    final event = _sidebarEvent;
    final now = utcNow();
    final saved = CalendarEvent(
      id: event?.id ?? newId(),
      title: result['title'] as String,
      start: result['start'] as DateTime,
      end: result['end'] as DateTime,
      isFullDay: result['isFullDay'] as bool,
      colorValue: result['colorValue'] as int,
      notes: result['notes'] as String,
      recurrence: result['recurrence'] as EventRecurrence? ?? EventRecurrence.none,
      source: event?.source ?? EventSource.local,
      externalId: event?.externalId,
      createdAt: event?.createdAt ?? now,
      updatedAt: now,
    );
    await ref.read(calendarRepositoryProvider).upsertEvent(saved);
    ref.invalidate(calendarEventsProvider);
    if (mounted) _closeSidebar();
  }

  Future<void> _openEditor({CalendarEvent? event, DateTime? day}) async {
    _openEventSidebar(event: event, day: day);
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

  void _shiftFocus(int delta, {required bool weekStartsMonday}) {
    _abortMorphAnimation();
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _isWeekMorphing = false;
      _weekMorphForward = true;
      _clearWeekMorphCache();
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
      if (_mode == CalendarViewMode.month) {
        _rememberViewedMonth(_focused);
      } else if (_mode == CalendarViewMode.week) {
        _rememberViewedWeek(_focused, weekStartsMonday);
      }
    });
  }

  String _headerLabel(bool weekStartsMonday) => switch (_mode) {
    CalendarViewMode.week =>
      'Week of ${DateFormat.MMMd().format(_weekStart(_focused, weekStartsMonday))}',
    CalendarViewMode.month => DateFormat.yMMMM().format(_focused),
    CalendarViewMode.year => '${_focused.year}',
  };

  String _weekMorphHeaderLabel(bool weekStartsMonday) {
    final anchor = _weekMorphAnchor ?? _focused;
    return 'Week of ${DateFormat.MMMd().format(_weekStart(anchor, weekStartsMonday))}';
  }

  Widget _buildMorphFocusHeader(BuildContext context, bool weekStartsMonday) {
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    return AnimatedBuilder(
      animation: _weekMorphController,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_weekMorphController.value);
        final opacity = (_weekMorphForward ? t : 1.0 - t).clamp(0.0, 1.0);
        if (opacity <= 0) return const SizedBox.shrink();
        return Opacity(
          opacity: opacity,
          child: IgnorePointer(
            child: _buildFocusHeaderControls(
              weekStartsMonday: weekStartsMonday,
              label: Text(
                _weekMorphHeaderLabel(weekStartsMonday),
                style: titleStyle,
              ),
            ),
          ),
        );
      },
    );
  }

  void _onWeekTimelineScrolled() {
    _weekTimelineScrollOffset = calendarWeekEffectiveScrollOffset(
      _weekTimelineScrollController,
      _weekTimelineScrollOffset,
    );
  }

  void _captureWeekTimelineScrollOffset() {
    _onWeekTimelineScrolled();
  }

  @override
  void dispose() {
    _disposeMorphListener();
    _disposeWeekMorphListener();
    _weekTimelineScrollController.removeListener(_onWeekTimelineScrolled);
    _zoomController.dispose();
    _weekMorphController.dispose();
    _weekTimelineScrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Animation helpers
  // ---------------------------------------------------------------------------

  (TextStyle compact, TextStyle full) _weekdayMorphStyles(
    BuildContext context,
  ) => _calendarWeekdayMorphStyles(context);

  (TextStyle yearMonth, TextStyle monthTitle) _titleMorphStyles(
    BuildContext context,
  ) => _calendarTitleMorphStyles(context);

  int _weekRowForDate(
    DateTime month,
    DateTime day,
    bool weekStartsMonday,
  ) {
    final dates = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    final idx = dates.indexWhere((d) => calendarSameDay(d, day));
    if (idx < 0) return 0;
    return idx ~/ 7;
  }

  /// Anchor for month→week morph: saved week when visible in [visibleMonth],
  /// else focused day when it lies in that month, otherwise the 1st.
  DateTime _weekMorphAnchorDate(DateTime visibleMonth, bool weekStartsMonday) {
    final saved = _lastViewedWeekStart;
    if (saved != null) {
      final weekStart = _weekStart(saved, weekStartsMonday);
      final dates = monthGridDates(visibleMonth, weekStartsMonday: weekStartsMonday);
      for (var i = 0; i < 7; i++) {
        final day = weekStart.add(Duration(days: i));
        if (dates.any((d) => calendarSameDay(d, day))) return day;
      }
    }
    if (_focused.year == visibleMonth.year &&
        _focused.month == visibleMonth.month) {
      return _focused;
    }
    return visibleMonth;
  }

  void _onMonthToWeek(bool weekStartsMonday) {
    if (_isWeekMorphing ||
        _isZooming ||
        _isChainedWeekToYear ||
        _isChainedYearToWeek) {
      return;
    }

    final morphMonth = DateTime(_focused.year, _focused.month, 1);
    final started = _beginMonthToWeekMorph(
      weekStartsMonday: weekStartsMonday,
      morphMonth: morphMonth,
      onComplete: () {
        if (!mounted) return;
        final anchor = _weekMorphAnchor ?? morphMonth;
        setState(() {
          _isWeekMorphing = false;
          _weekMorphForward = true;
          _clearWeekMorphCache();
          _mode = CalendarViewMode.week;
          _focused = _weekStart(anchor, weekStartsMonday);
          _rememberViewedWeek(_focused, weekStartsMonday);
          _weekMorphController.duration = _weekMorphDuration;
        });
      },
    );

    if (!started) return;
  }

  /// Month → week zoom-in. Returns false when morph state could not be started.
  bool _beginMonthToWeekMorph({
    required bool weekStartsMonday,
    required DateTime morphMonth,
    Duration? duration,
    required VoidCallback onComplete,
  }) {
    if (_isWeekMorphing || _isZooming) return false;

    final cache = _layoutCache;
    if (cache == null) return false;

    _captureWeekTimelineScrollOffset();
    final anchor = _weekMorphAnchorDate(morphMonth, weekStartsMonday);
    final weekRow = _weekRowForDate(morphMonth, anchor, weekStartsMonday);
    final generation = _prepareWeekMorphSession();

    if (duration != null) {
      _weekMorphController.duration = duration;
    }

    setState(() {
      _isWeekMorphing = true;
      _weekMorphForward = true;
      _weekMorphWeekRow = weekRow;
      _weekMorphAnchor = anchor;
      _rememberViewedMonth(morphMonth);
      _weekMorphEvents = List<CalendarEvent>.from(_latestEvents);
      _weekMorphIndicators = List<CalendarDayIndicator>.from(
        _latestIndicators,
      );
      _weekMorphTodos = List<CalendarTodoMarker>.from(_latestTodos);
    });

    _startWeekMorphAnimation(
      generation: generation,
      reverse: false,
      onComplete: onComplete,
    );
    return true;
  }

  void _onWeekToMonth(bool weekStartsMonday) {
    if (_isWeekMorphing ||
        _isZooming ||
        _isChainedWeekToYear ||
        _isChainedYearToWeek) {
      return;
    }

    final cache = _layoutCache;
    if (cache == null) {
      _rememberViewedWeek(_focused, weekStartsMonday);
      setState(() {
        _mode = CalendarViewMode.month;
        _focused = _visibleMonthForWeekReturn(weekStartsMonday);
      });
      return;
    }

    _beginWeekToMonthMorph(
      weekStartsMonday: weekStartsMonday,
      onComplete: (morphMonth) {
        if (!mounted) return;
        setState(() {
          _isWeekMorphing = false;
          _weekMorphForward = true;
          _clearWeekMorphCache();
          _mode = CalendarViewMode.month;
          _focused = morphMonth;
          _rememberViewedMonth(morphMonth);
          _weekMorphController.duration = _weekMorphDuration;
        });
      },
    );
  }

  /// Week → month phase. Returns false when morph state could not be started.
  bool _beginWeekToMonthMorph({
    required bool weekStartsMonday,
    Duration? duration,
    required void Function(DateTime morphMonth) onComplete,
  }) {
    if (_isWeekMorphing || _isZooming) return false;

    final cache = _layoutCache;
    if (cache == null) return false;

    final morphMonth = _visibleMonthForWeekReturn(weekStartsMonday);
    _rememberViewedWeek(_focused, weekStartsMonday);
    _captureWeekTimelineScrollOffset();
    final anchor = _focused;
    final weekRow = _weekRowForDate(morphMonth, anchor, weekStartsMonday);
    final generation = _prepareWeekMorphSession(resetValue: false);

    if (duration != null) {
      _weekMorphController.duration = duration;
    }

    setState(() {
      _isWeekMorphing = true;
      _weekMorphForward = false;
      _weekMorphWeekRow = weekRow;
      _weekMorphAnchor = anchor;
      _weekMorphEvents = List<CalendarEvent>.from(_latestEvents);
      _weekMorphIndicators = List<CalendarDayIndicator>.from(
        _latestIndicators,
      );
      _weekMorphTodos = List<CalendarTodoMarker>.from(_latestTodos);
    });
    _weekMorphController.value = 1.0;

    _startWeekMorphAnimation(
      generation: generation,
      reverse: true,
      onComplete: () => onComplete(morphMonth),
    );
    return true;
  }

  void _onWeekToYear(bool weekStartsMonday) {
    if (_isWeekMorphing ||
        _isZooming ||
        _isChainedWeekToYear ||
        _isChainedYearToWeek) {
      return;
    }

    final cache = _layoutCache;
    if (cache == null) {
      _rememberViewedWeek(_focused, weekStartsMonday);
      _immediatelySwitchToYear();
      return;
    }

    _isChainedWeekToYear = true;

    final started = _beginWeekToMonthMorph(
      weekStartsMonday: weekStartsMonday,
      duration: _chainedMorphDuration,
      onComplete: (morphMonth) {
        if (!mounted || !_isChainedWeekToYear) return;
        _handoffChainedWeekToYearMorph(morphMonth);
      },
    );

    if (!started) {
      _isChainedWeekToYear = false;
      _weekMorphController.duration = _weekMorphDuration;
      _immediatelySwitchToYear();
    }
  }

  void _handoffChainedWeekToYearMorph(DateTime morphMonth) {
    if (!mounted || !_isChainedWeekToYear) return;

    final cache = _layoutCache;
    if (cache == null) {
      _isChainedWeekToYear = false;
      _weekMorphController.duration = _weekMorphDuration;
      _immediatelySwitchToYear();
      return;
    }

    final idx = morphMonth.month - 1;
    final morphTileRect = cache.tileBounds[idx];
    final sourceRects = cache.destRects;
    final destRects = cache.tileSourceRects[idx];
    final areaSize = cache.areaSize;

    _yearMatrixTween = Matrix4Tween(
      begin: cache.tileZoomMatrices[idx],
      end: Matrix4.identity(),
    );

    final generation = _prepareMorphSession();
    _zoomController.duration = _chainedMorphDuration;

    setState(() {
      _isWeekMorphing = false;
      _weekMorphForward = true;
      _clearWeekMorphCache();
      _focused = morphMonth;
      _rememberViewedMonth(morphMonth);
      _mode = CalendarViewMode.month;
      _isZooming = true;
      _morphReverse = true;
      _morphSourceRects = sourceRects;
      _morphDestRects = destRects;
      _morphMonth = morphMonth;
      _morphTileRect = morphTileRect;
      _morphAreaSize = areaSize;
      _morphEvents = List<CalendarEvent>.from(_latestEvents);
      _morphIndicators = List<CalendarDayIndicator>.from(_latestIndicators);
      _morphTodos = List<CalendarTodoMarker>.from(_latestTodos);
    });

    _startMorphAnimation(
      generation: generation,
      onComplete: () {
        if (!mounted) return;
        setState(() {
          _isChainedWeekToYear = false;
          _isZooming = false;
          _morphReverse = false;
          _mode = CalendarViewMode.year;
          _focused = DateTime(morphMonth.year, 1, 1);
          _clearMorphCache();
          _weekMorphController.duration = _weekMorphDuration;
          _zoomController.duration = _zoomDuration;
        });
      },
    );
  }

  void _onYearToWeek(bool weekStartsMonday) {
    if (_isWeekMorphing ||
        _isZooming ||
        _isChainedWeekToYear ||
        _isChainedYearToWeek) {
      return;
    }

    final cache = _layoutCache;
    final targetMonth = _monthTargetForYear(_focused.year);
    if (cache == null) {
      _immediatelySwitchToWeek(weekStartsMonday, targetMonth);
      return;
    }

    _isChainedYearToWeek = true;

    final started = _beginYearToMonthMorph(
      month: targetMonth,
      duration: _chainedMorphDuration,
      onComplete: () {
        if (!mounted || !_isChainedYearToWeek) return;
        _handoffChainedYearToWeekMorph(weekStartsMonday, targetMonth);
      },
    );

    if (!started) {
      _isChainedYearToWeek = false;
      _zoomController.duration = _zoomDuration;
      _immediatelySwitchToWeek(weekStartsMonday, targetMonth);
    }
  }

  void _handoffChainedYearToWeekMorph(
    bool weekStartsMonday,
    DateTime morphMonth,
  ) {
    if (!mounted || !_isChainedYearToWeek) return;

    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _focused = morphMonth;
      _rememberViewedMonth(morphMonth);
    });

    final started = _beginMonthToWeekMorph(
      weekStartsMonday: weekStartsMonday,
      morphMonth: morphMonth,
      duration: _chainedMorphDuration,
      onComplete: () {
        if (!mounted) return;
        final anchor = _weekMorphAnchor ?? morphMonth;
        setState(() {
          _isChainedYearToWeek = false;
          _isWeekMorphing = false;
          _weekMorphForward = true;
          _clearWeekMorphCache();
          _mode = CalendarViewMode.week;
          _focused = _weekStart(anchor, weekStartsMonday);
          _rememberViewedWeek(_focused, weekStartsMonday);
          _weekMorphController.duration = _weekMorphDuration;
          _zoomController.duration = _zoomDuration;
        });
      },
    );

    if (!started) {
      _isChainedYearToWeek = false;
      _weekMorphController.duration = _weekMorphDuration;
      _zoomController.duration = _zoomDuration;
      _immediatelySwitchToWeek(weekStartsMonday, morphMonth);
    }
  }

  void _onYearToMonth() {
    _onMonthTapped(_monthTargetForYear(_focused.year));
  }

  void _onMonthTapped(DateTime month) {
    if (_isZooming ||
        _isWeekMorphing ||
        _isChainedWeekToYear ||
        _isChainedYearToWeek) {
      return;
    }

    if (_layoutCache == null) return;

    _beginYearToMonthMorph(
      month: month,
      onComplete: () {
        if (!mounted) return;
        setState(() {
          _isZooming = false;
          _clearMorphCache();
          _zoomController.duration = _zoomDuration;
        });
      },
    );
  }

  /// Year → month zoom-in. Returns false when morph state could not be started.
  bool _beginYearToMonthMorph({
    required DateTime month,
    Duration? duration,
    required VoidCallback onComplete,
  }) {
    if (_isZooming || _isWeekMorphing) return false;

    final cache = _layoutCache;
    if (cache == null) return false;

    final morphMonth = DateTime(month.year, month.month, 1);
    final idx = morphMonth.month - 1;
    final morphTileRect = cache.tileBounds[idx];
    final sourceRects = cache.tileSourceRects[idx];
    final zoomMatrixEnd = cache.tileZoomMatrices[idx];
    final destRects = cache.destRects;
    final areaSize = cache.areaSize;

    _yearMatrixTween = Matrix4Tween(
      begin: Matrix4.identity(),
      end: zoomMatrixEnd,
    );

    final generation = _prepareMorphSession();

    if (duration != null) {
      _zoomController.duration = duration;
    }

    setState(() {
      _focused = morphMonth;
      _rememberViewedMonth(morphMonth);
      _dayViewDate = null;
      _mode = CalendarViewMode.month;
      _isZooming = true;
      _morphReverse = false;
      _morphSourceRects = sourceRects;
      _morphDestRects = destRects;
      _morphMonth = morphMonth;
      _morphTileRect = morphTileRect;
      _morphAreaSize = areaSize;
      _morphEvents = List<CalendarEvent>.from(_latestEvents);
      _morphIndicators = List<CalendarDayIndicator>.from(_latestIndicators);
      _morphTodos = List<CalendarTodoMarker>.from(_latestTodos);
    });

    _startMorphAnimation(generation: generation, onComplete: onComplete);
    return true;
  }

  void _onViewModeSelectionChanged(
    Set<CalendarViewMode> selection, {
    required bool weekStartsMonday,
  }) {
    final next = selection.first;

    if (_dayViewDate != null) {
      _abortMorphAnimation();
      setState(() {
        _dayViewDate = null;
        _mode = next;
        if (next == CalendarViewMode.year) {
          _focused = DateTime(_focused.year, 1, 1);
        } else if (next == CalendarViewMode.month) {
          _focused = DateTime(_focused.year, _focused.month, 1);
        } else {
          _focused = _weekStart(_focused, weekStartsMonday);
        }
      });
      return;
    }

    if (next == CalendarViewMode.week &&
        _mode == CalendarViewMode.month &&
        !_isZooming &&
        !_isWeekMorphing &&
        _dayViewDate == null) {
      _onMonthToWeek(weekStartsMonday);
      return;
    }

    if (next == CalendarViewMode.month &&
        _mode == CalendarViewMode.week &&
        !_isZooming &&
        !_isWeekMorphing &&
        _dayViewDate == null) {
      _onWeekToMonth(weekStartsMonday);
      return;
    }

    // Trigger the forward zoom animation when switching year → month.
    if (next == CalendarViewMode.month &&
        _mode == CalendarViewMode.year &&
        !_isZooming &&
        !_isWeekMorphing &&
        _dayViewDate == null) {
      _onYearToMonth();
      return;
    }

    // Trigger the reverse zoom animation when switching month → year.
    if (next == CalendarViewMode.year &&
        _mode == CalendarViewMode.month &&
        !_isZooming &&
        !_isWeekMorphing &&
        !_isChainedWeekToYear &&
        !_isChainedYearToWeek &&
        _dayViewDate == null) {
      _onReverseToYear();
      return;
    }

    // Chained week → month (400 ms) → year (400 ms).
    if (next == CalendarViewMode.year &&
        _mode == CalendarViewMode.week &&
        !_isZooming &&
        !_isWeekMorphing &&
        !_isChainedWeekToYear &&
        !_isChainedYearToWeek &&
        _dayViewDate == null) {
      _onWeekToYear(weekStartsMonday);
      return;
    }

    // Chained year → month (400 ms) → week (400 ms).
    if (next == CalendarViewMode.week &&
        _mode == CalendarViewMode.year &&
        !_isZooming &&
        !_isWeekMorphing &&
        !_isChainedWeekToYear &&
        !_isChainedYearToWeek &&
        _dayViewDate == null) {
      _onYearToWeek(weekStartsMonday);
      return;
    }

    _abortMorphAnimation();
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _isWeekMorphing = false;
      _weekMorphForward = true;
      _clearWeekMorphCache();
      if (_dayViewDate != null) {
        _dayViewDate = null;
      }
      if (_mode == CalendarViewMode.week) {
        _rememberViewedWeek(_focused, weekStartsMonday);
      }
      _mode = next;
      if (next == CalendarViewMode.year) {
        _focused = DateTime(_focused.year, 1, 1);
      } else if (next == CalendarViewMode.month) {
        _focused = _mode == CalendarViewMode.week
            ? _visibleMonthForWeekReturn(weekStartsMonday)
            : _monthTargetForYear(_focused.year);
      }
    });
  }

  /// Starts the reverse zoom animation (month → year).
  ///
  /// Mirrors [_onMonthTapped] with source/dest roles swapped:
  ///   source (t=0) = full month-view cell positions ([CalendarLayoutCache.destRects])
  ///   dest   (t=1) = year-tile cell positions ([CalendarLayoutCache.tileSourceRects])
  /// The [Matrix4Tween] runs from zoomed-in → identity so the year grid flies
  /// back in rather than out.
  void _onReverseToYear() {
    if (_isZooming || _isWeekMorphing) return;

    final morphMonth = DateTime(_focused.year, _focused.month, 1);
    _rememberViewedMonth(morphMonth);
    if (_layoutCache == null) {
      _immediatelySwitchToYear();
      return;
    }

    _beginMonthToYearMorph(
      morphMonth: morphMonth,
      onComplete: () {
        if (!mounted) return;
        setState(() {
          _isZooming = false;
          _morphReverse = false;
          _mode = CalendarViewMode.year;
          _focused = DateTime(morphMonth.year, 1, 1);
          _clearMorphCache();
          _zoomController.duration = _zoomDuration;
        });
      },
    );
  }

  /// Month → year zoom-out. Returns false when morph state could not be started.
  bool _beginMonthToYearMorph({
    required DateTime morphMonth,
    Duration? duration,
    required VoidCallback onComplete,
  }) {
    if (_isZooming) return false;

    final cache = _layoutCache;
    if (cache == null) return false;

    final idx = morphMonth.month - 1;
    final morphTileRect = cache.tileBounds[idx];
    final sourceRects = cache.destRects;
    final destRects = cache.tileSourceRects[idx];
    final areaSize = cache.areaSize;

    _yearMatrixTween = Matrix4Tween(
      begin: cache.tileZoomMatrices[idx],
      end: Matrix4.identity(),
    );

    final generation = _prepareMorphSession();

    if (duration != null) {
      _zoomController.duration = duration;
    }

    setState(() {
      _isZooming = true;
      _morphReverse = true;
      _morphSourceRects = sourceRects;
      _morphDestRects = destRects;
      _morphMonth = morphMonth;
      _morphTileRect = morphTileRect;
      _morphAreaSize = areaSize;
      _morphEvents = List<CalendarEvent>.from(_latestEvents);
      _morphIndicators = List<CalendarDayIndicator>.from(_latestIndicators);
      _morphTodos = List<CalendarTodoMarker>.from(_latestTodos);
      _focused = morphMonth;
    });

    _startMorphAnimation(generation: generation, onComplete: onComplete);
    return true;
  }

  /// Falls back to an immediate view switch when measurement is unavailable.
  void _immediatelySwitchToYear() {
    if (_mode == CalendarViewMode.month) {
      _rememberViewedMonth(_focused);
    }
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _mode = CalendarViewMode.year;
      _focused = DateTime(_focused.year, 1, 1);
      _dayViewDate = null;
    });
  }

  void _immediatelySwitchToWeek(bool weekStartsMonday, DateTime morphMonth) {
    final anchor = _weekMorphAnchorDate(morphMonth, weekStartsMonday);
    final weekStart = _weekStart(anchor, weekStartsMonday);
    setState(() {
      _isZooming = false;
      _isWeekMorphing = false;
      _morphReverse = false;
      _clearMorphCache();
      _clearWeekMorphCache();
      _mode = CalendarViewMode.week;
      _focused = weekStart;
      _rememberViewedMonth(morphMonth);
      _rememberViewedWeek(weekStart, weekStartsMonday);
      _dayViewDate = null;
    });
  }

  void _instantSwitchToMonthView(bool weekStartsMonday) {
    _abortMorphAnimation();
    final fromYear = _mode == CalendarViewMode.year;
    setState(() {
      _isZooming = false;
      _morphReverse = false;
      _clearMorphCache();
      _isWeekMorphing = false;
      _weekMorphForward = true;
      _clearWeekMorphCache();
      _mode = CalendarViewMode.month;
      _focused = fromYear
          ? _monthTargetForYear(_focused.year)
          : _visibleMonthForWeekReturn(weekStartsMonday);
      if (fromYear) {
        _rememberViewedMonth(_focused);
      }
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
          onPressed: () => _shiftFocus(-1, weekStartsMonday: weekStartsMonday),
          icon: const Icon(PhosphorIconsRegular.caretLeft),
        ),
        label,
        IconButton(
          onPressed: () => _shiftFocus(1, weekStartsMonday: weekStartsMonday),
          icon: const Icon(PhosphorIconsRegular.caretRight),
        ),
      ],
    );
  }

  Widget _buildViewModeSelector(bool weekStartsMonday) {
    final onSelectionChanged = (Set<CalendarViewMode> selection) =>
        _onViewModeSelectionChanged(
          selection,
          weekStartsMonday: weekStartsMonday,
        );
    final interactive = !_isZooming && !_isWeekMorphing;

    if (_isWeekMorphing) {
      return AnimatedBuilder(
        animation: _weekMorphController,
        builder: (context, _) {
          final t = Curves.easeInOutCubic.transform(_weekMorphController.value);
          return _ViewModeSegmentedControl(
            weekSelect: t,
            monthSelect: 1.0 - t,
            yearSelect: 0.0,
            onSelectionChanged: onSelectionChanged,
            interactive: interactive,
          );
        },
      );
    }

    if (_isZooming) {
      return AnimatedBuilder(
        animation: _zoomController,
        builder: (context, _) {
          final t = Curves.easeInOutCubic.transform(_zoomController.value);
          if (_morphReverse) {
            return _ViewModeSegmentedControl(
              weekSelect: 0.0,
              monthSelect: 1.0 - t,
              yearSelect: t,
              onSelectionChanged: onSelectionChanged,
              interactive: interactive,
            );
          }
          return _ViewModeSegmentedControl(
            weekSelect: 0.0,
            monthSelect: t,
            yearSelect: 1.0 - t,
            onSelectionChanged: onSelectionChanged,
            interactive: interactive,
          );
        },
      );
    }

    return _ViewModeSegmentedControl(
      weekSelect: _dayViewDate != null
          ? 0.0
          : (_mode == CalendarViewMode.week ? 1.0 : 0.0),
      monthSelect: _dayViewDate != null
          ? 0.0
          : (_mode == CalendarViewMode.month ? 1.0 : 0.0),
      yearSelect: _dayViewDate != null
          ? 0.0
          : (_mode == CalendarViewMode.year ? 1.0 : 0.0),
      onSelectionChanged: onSelectionChanged,
      interactive: interactive,
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
    required List<CalendarTodoMarker> todoMarkers,
    required bool showTodoIcons,
    required bool weekStartsMonday,
    required CalendarViewMode mode,
    required DateTime focused,
    DateTime? hiddenMonth,
    int? hiddenWeekRow,
    bool showMonthChrome = true,
    bool monthNavigation = false,
  }) {
    return CalendarGrid(
      mode: mode,
      focused: focused,
      events: events,
      indicators: indicators,
      todoMarkers: mode == CalendarViewMode.year ? const [] : todoMarkers,
      showTodoIcons: mode == CalendarViewMode.year ? false : showTodoIcons,
      weekStartsMonday: weekStartsMonday,
      onDayTap: (day) => _openEventSidebar(day: day),
      onMonthTap: _onMonthTapped,
      onEventTap: (event) => _openEventSidebar(event: event),
      onTodoTap: _openTodoSidebar,
      onWeekSlotTap: _openWeekSlotSidebar,
      onEntryTap: _handleEntryTap,
      hiddenMonth: hiddenMonth,
      hiddenWeekRow: hiddenWeekRow,
      showMonthChrome: showMonthChrome,
      onPreviousMonth: monthNavigation
          ? () => _shiftFocus(-1, weekStartsMonday: weekStartsMonday)
          : null,
      onNextMonth: monthNavigation
          ? () => _shiftFocus(1, weekStartsMonday: weekStartsMonday)
          : null,
      weekTimelineScrollController: _weekTimelineScrollController,
    );
  }

  /// Inactive month rows (5 of 6) for the week morph — no card, no chrome.
  Widget _buildInactiveMonthRows({
    required BuildContext context,
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required List<CalendarTodoMarker> todoMarkers,
    required bool weekStartsMonday,
    required DateTime morphMonth,
    required int hiddenWeekRow,
    required TextStyle monthTitleStyle,
    required TextStyle monthWeekdayStyle,
  }) {
    final chromeSpacer =
        MonthTitleHeader.preferredHeight(monthTitleStyle) +
        MonthTitleHeader.titleGap +
        WeekdayHeaderRow.totalHeight(monthWeekdayStyle);

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.all(MonthTitleHeader.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: chromeSpacer),
            Expanded(
              child: MonthDayGrid(
                month: morphMonth,
                events: events,
                indicators: indicators,
                todoMarkers: todoMarkers,
                showTodoIcons: false,
                weekStartsMonday: weekStartsMonday,
                style: MonthDayCellStyle.full,
                hiddenWeekRow: hiddenWeekRow,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Month view uses a stable [Stack] so the live grid survives morph handoff.
  Widget _buildMonthCalendarStack({
    required Widget monthGrid,
    Widget? morphOverlay,
  }) {
    final morphing = morphOverlay != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Visibility(
          visible: !morphing,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: IgnorePointer(ignoring: morphing, child: monthGrid),
        ),
        ?morphOverlay,
      ],
    );
  }

  Widget _buildMainCalendar({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required List<CalendarTodoMarker> todoMarkers,
    required bool weekStartsMonday,
  }) {
    final activeEvents = _weekMorphEvents ?? _morphEvents ?? events;
    final activeIndicators = _weekMorphIndicators ?? _morphIndicators ?? indicators;
    final activeTodos = _weekMorphTodos ?? _morphTodos ?? todoMarkers;
    final showTodoIcons = !_isZooming && !_isWeekMorphing;

    if (_dayViewDate != null) {
      return DayHourGrid(
        day: _dayViewDate!,
        events: events,
        todoMarkers: todoMarkers,
        onHourTap: (hour) => _openEditor(day: hour),
        onDayChanged: (day) => setState(() {
          _dayViewDate = day;
          _focused = DateTime(day.year, day.month, 1);
        }),
      );
    }

    if (_isWeekMorphing && _layoutCache != null && _weekMorphAnchor != null) {
      final cache = _layoutCache!;
      final morphMonth = _weekMorphForward
          ? DateTime(_focused.year, _focused.month, 1)
          : _visibleMonthForWeekReturn(weekStartsMonday);
      final weekRow = _weekMorphWeekRow;
      final anchor = _weekMorphAnchor!;
      final monthRowRects = cache.monthCellRects.sublist(
        weekRow * 7,
        weekRow * 7 + 7,
      );
      final monthTitleStyle = _titleMorphStyles(context).$2;
      final monthWeekdayStyle = calendarWeekdayLabelStyle(context);
      final weekWeekdayStyle = calendarWeekdayLabelStyle(
        context,
        fontSize: calendarWeekWeekdayFontSize,
      );

      return _MonthWeekMorphLayer(
        key: ValueKey(_weekMorphGeneration),
        controller: _weekMorphController,
        morphMonth: morphMonth,
        anchor: anchor,
        weekRow: weekRow,
        monthRowRects: monthRowRects,
        weekColumnRects: cache.weekColumnRects,
        monthCardRect: cache.monthCardRect,
        weekAreaRect: cache.weekAreaRect,
        monthWeekdayHeaderY: cache.monthWeekdayHeaderY,
        weekWeekdayHeaderY: cache.weekWeekdayHeaderY,
        areaSize: cache.areaSize,
        weekStartsMonday: weekStartsMonday,
        monthWeekdayStyle: monthWeekdayStyle,
        weekWeekdayStyle: weekWeekdayStyle,
        monthTitleStyle: monthTitleStyle,
        events: activeEvents,
        indicators: activeIndicators,
        todoMarkers: activeTodos,
        inactiveMonthRows: _buildInactiveMonthRows(
          context: context,
          events: activeEvents,
          indicators: activeIndicators,
          todoMarkers: activeTodos,
          weekStartsMonday: weekStartsMonday,
          morphMonth: morphMonth,
          hiddenWeekRow: weekRow,
          monthTitleStyle: monthTitleStyle,
          monthWeekdayStyle: monthWeekdayStyle,
        ),
        weekTimelineScrollController: _weekTimelineScrollController,
        weekTimelineScrollOffset: _weekTimelineScrollOffset,
        weekMorphForward: _weekMorphForward,
        weekStart: _weekStart(anchor, weekStartsMonday),
      );
    }

    if (_isZooming &&
        _yearMatrixTween != null &&
        _morphSourceRects != null &&
        _morphDestRects != null &&
        _morphMonth != null &&
        _morphTileRect != null &&
        _morphAreaSize != null) {
      final morphMonth = _morphMonth!;
      final sourceRects = _morphSourceRects!;
      final yearTween = _yearMatrixTween!;
      final controller = _zoomController;
      final tileRect = _morphTileRect!;
      final areaSize = _morphAreaSize!;

      final (compactWeekdayStyle, fullWeekdayStyle) = _weekdayMorphStyles(
        context,
      );
      final (yearMonthNameStyle, monthTitleStyleForMorph) = _titleMorphStyles(
        context,
      );

      final morphLayer = _MorphAnimationLayer(
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
        weekStartsMonday: weekStartsMonday,
        compactWeekdayStyle: compactWeekdayStyle,
        fullWeekdayStyle: fullWeekdayStyle,
        yearMonthNameStyle: yearMonthNameStyle,
        monthTitleStyle: monthTitleStyleForMorph,
        yearGrid: _calendarGrid(
          events: activeEvents,
          indicators: activeIndicators,
          todoMarkers: activeTodos,
          showTodoIcons: false,
          weekStartsMonday: weekStartsMonday,
          mode: CalendarViewMode.year,
          focused: DateTime(morphMonth.year, 1, 1),
          hiddenMonth: morphMonth,
        ),
        events: activeEvents,
        todoMarkers: activeTodos,
        monthMorphEventMetrics: _layoutCache!.monthMorphEventMetrics,
      );

      if (!_morphReverse) {
        return _buildMonthCalendarStack(
          monthGrid: _calendarGrid(
            events: activeEvents,
            indicators: activeIndicators,
            todoMarkers: activeTodos,
            showTodoIcons: false,
            weekStartsMonday: weekStartsMonday,
            mode: CalendarViewMode.month,
            focused: morphMonth,
            monthNavigation: true,
          ),
          morphOverlay: morphLayer,
        );
      }

      return morphLayer;
    }

    return _calendarGrid(
      events: activeEvents,
      indicators: activeIndicators,
      todoMarkers: activeTodos,
      showTodoIcons: showTodoIcons,
      weekStartsMonday: weekStartsMonday,
      mode: _mode,
      focused: _mode == CalendarViewMode.year
          ? DateTime(_focused.year, 1, 1)
          : _focused,
      monthNavigation: _mode == CalendarViewMode.month,
    );
  }

  Widget _buildSidebar() {
    switch (_sidebarKind) {
      case _CalendarSidebarKind.none:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            if (ref.watch(devSettingsProvider).showCalendarInstantViewSwitch) ...[
              OutlinedButton(
                onPressed: () => _instantSwitchToMonthView(
                  ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true,
                ),
                child: const Text('Month'),
              ),
              const SizedBox(height: 4),
              OutlinedButton(
                onPressed: _instantSwitchToYearView,
                child: const Text('Year'),
              ),
            ],
          ],
        );
      case _CalendarSidebarKind.event:
        return CalendarEventPanel(
          key: ValueKey(
            _sidebarEvent?.id ??
                'new-${_sidebarEventInitialDate?.millisecondsSinceEpoch}',
          ),
          event: _sidebarEvent,
          initialDate: _sidebarEventInitialDate ?? _focused,
          onSave: _saveSidebarEvent,
          onCancel: _closeSidebar,
        );
      case _CalendarSidebarKind.todo:
        final task = _sidebarTodo;
        if (task == null) return const SizedBox.shrink();
        final lists = ref.watch(todoListsProvider).valueOrNull ?? const [];
        final listColors = {
          for (final list in lists) list.id: list.colorValue,
        };
        return TodoEditPanel(
          key: ValueKey(task.id),
          task: task,
          listColor: listColors[task.listId],
          lists: lists,
          onClose: () {
            ref.invalidate(calendarTodoMarkersProvider);
            ref.invalidate(allTodoTasksProvider);
            _closeSidebar();
          },
          onChanged: () {
            ref.invalidate(calendarTodoMarkersProvider);
            ref.invalidate(allTodoTasksProvider);
          },
          onDeleted: () {
            ref.invalidate(calendarTodoMarkersProvider);
            ref.invalidate(allTodoTasksProvider);
            _closeSidebar();
          },
          onToggleStar: () async {
            final updated = task.copyWith(starred: !task.starred);
            await ref.read(todoRepositoryProvider).upsertTask(updated);
            ref.invalidate(calendarTodoMarkersProvider);
            ref.invalidate(allTodoTasksProvider);
            if (mounted) {
              setState(() => _sidebarTodo = updated);
            }
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final eventsAsync = ref.watch(calendarEventsProvider);
    final todosAsync = ref.watch(calendarTodoMarkersProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final weekStartsMonday = settings.weekStartsOnMonday;

    const indicators = <CalendarDayIndicator>[];

    return CalendarKeyboardShortcuts(
      navigateLeftKey: settings.calendarNavigateLeftKey,
      navigateRightKey: settings.calendarNavigateRightKey,
      onNavigate: (delta) => _shiftFocus(delta, weekStartsMonday: weekStartsMonday),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _buildViewModeSelector(weekStartsMonday),
                    const Spacer(),
                    if (_isWeekMorphing)
                      _buildMorphFocusHeader(context, weekStartsMonday)
                    else if (_mode != CalendarViewMode.month &&
                        _dayViewDate == null)
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
                      final todos = todosAsync.valueOrNull ?? const <CalendarTodoMarker>[];
                      final calendarEvents =
                          _isWeekMorphing && _weekMorphEvents != null
                          ? _weekMorphEvents!
                          : _isZooming && _morphEvents != null
                          ? _morphEvents!
                          : events;
                      if (!_isZooming && !_isWeekMorphing) {
                        _latestEvents = events;
                        _latestIndicators = indicators;
                        _latestTodos = todos;
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: _sidebarWidth,
                            child: _buildSidebar(),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                _refreshLayoutCache(constraints.biggest);
                                return KeyedSubtree(
                                  key: _calendarAreaKey,
                                  child: _buildMainCalendar(
                                    events: calendarEvents,
                                    indicators: indicators,
                                    todoMarkers: todos,
                                    weekStartsMonday: weekStartsMonday,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('$e')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Shared style helpers (used by _CalendarPageState and CalendarMorphWarmup)
// =============================================================================

(TextStyle compact, TextStyle full) _calendarWeekdayMorphStyles(
  BuildContext context,
) {
  final full = calendarWeekdayLabelStyle(context);
  final compact = calendarWeekdayLabelStyle(
    context,
    fontSize: MonthDayCellStyle.compact.fontSize,
  ).copyWith(inherit: false);
  return (compact, full);
}

(TextStyle yearMonth, TextStyle monthTitle) _calendarTitleMorphStyles(
  BuildContext context,
) {
  final color = calendarTitleAccentColor(context);
  final yearMonth = MonthTitleHeader.yearTileMonthNameStyle(context);
  final monthTitle = Theme.of(context).textTheme.titleSmall!.copyWith(
    fontSize: MonthTitleHeader.titleFontSize,
    color: color,
  );
  return (yearMonth, monthTitle);
}

/// Analytically computes 42 source [Rect]s for a year-tile given its geometry.
List<Rect> _calendarWarmupSourceRects(
  Rect tileRect,
  TextStyle yearTitleStyle,
  TextStyle compactWeekdayStyle,
) {
  const tilePadding = 6.0;
  final titleHeight =
      MonthTitleHeader.measureTitleText(yearTitleStyle, 'June').height;
  final weekdayHeight = WeekdayHeaderRow.totalHeight(
    compactWeekdayStyle,
    useSingleLetterLabels: true,
  );
  final gridLeft = tileRect.left + tilePadding;
  final gridTop =
      tileRect.top +
      tilePadding +
      titleHeight +
      MonthTitleHeader.titleGap +
      weekdayHeight;
  final gridW = tileRect.width - tilePadding * 2;
  final gridH = tileRect.height - (gridTop - tileRect.top) - tilePadding;
  final cellW = gridW / 7;
  final cellH = gridH / 6;
  return List.generate(
    42,
    (i) => Rect.fromLTWH(
      gridLeft + (i % 7) * cellW,
      gridTop + (i ~/ 7) * cellH,
      cellW,
      cellH,
    ),
  );
}

// =============================================================================
// CalendarLayoutCache — pre-computed morph geometry, zero render-object reads
// =============================================================================

/// Analytically pre-computes all geometry needed for the year↔month morph
/// animations so that neither the forward nor the reverse path needs to
/// measure any render objects at tap time.
///
/// All coordinates are in calendar-area-local space.  The cache is keyed on
/// [areaSize]; call [compute] again whenever the area resizes.
class CalendarLayoutCache {
  const CalendarLayoutCache._({
    required this.areaSize,
    required this.tileBounds,
    required this.tileSourceRects,
    required this.tileZoomMatrices,
    required this.destRects,
    required this.monthCellRects,
    required this.weekColumnRects,
    required this.monthCardRect,
    required this.weekAreaRect,
    required this.monthWeekdayHeaderY,
    required this.weekWeekdayHeaderY,
    required this.monthMorphEventMetrics,
  });

  /// The area size this cache was built for.
  final Size areaSize;

  /// Outer bounding [Rect] of each of the 12 year-grid tiles (index = month−1).
  final List<Rect> tileBounds;

  /// 42 source-cell [Rect]s inside each tile's [MonthDayGrid] (index = month−1).
  final List<List<Rect>> tileSourceRects;

  /// Zoom [Matrix4] (tile → full area) for each of the 12 tiles.
  final List<Matrix4> tileZoomMatrices;

  /// 42 destination-cell [Rect]s for the full-screen month view.
  final List<Rect> destRects;

  /// Same as [destRects] — every day cell in the month grid.
  final List<Rect> monthCellRects;

  /// Seven column [Rect]s for the week view day area.
  final List<Rect> weekColumnRects;

  /// Bounding box of the month view [Card] (area-local).
  final Rect monthCardRect;

  /// Flat bounding box of the week view (area-local).
  final Rect weekAreaRect;

  /// Top [Y] of the weekday label row in month view (area-local).
  final double monthWeekdayHeaderY;

  /// Top [Y] of the weekday label row in week view (area-local).
  final double weekWeekdayHeaderY;

  /// Frozen event-bar metrics indexed by event count (0…5) for month→year morph.
  final List<MorphDayEventFrozenMetrics> monthMorphEventMetrics;

  MorphDayEventFrozenMetrics morphEventMetricsFor(int eventCount) =>
      monthMorphEventMetrics[
          eventCount.clamp(0, MorphDayEventStack.maxMonthEvents)];

  // Year-grid layout constants — must match _YearGrid.
  static const _crossAxisCount = 3;
  static const _rowCount = 4;
  static const _crossAxisSpacing = 8.0;
  static const _mainAxisSpacing = 6.0;

  /// Gap below weekday labels in week view — must match [calendarWeekHeaderGap].
  static const weekHeaderGap = calendarWeekHeaderGap;

  /// Builds the cache from [areaSize] and resolved text styles.
  ///
  /// Pure math — no widget mounting, no frame waits, no render-object reads.
  factory CalendarLayoutCache.compute({
    required Size areaSize,
    required TextStyle yearTileNameStyle,
    required TextStyle compactWeekdayStyle,
    required TextStyle fullTitleStyle,
    required TextStyle fullWeekdayStyle,
    required TextStyle weekWeekdayStyle,
  }) {
    final tileW =
        (areaSize.width - _crossAxisSpacing * (_crossAxisCount - 1)) /
        _crossAxisCount;
    final tileH =
        (areaSize.height - _mainAxisSpacing * (_rowCount - 1)) / _rowCount;

    final tileBounds = <Rect>[];
    final tileSourceRects = <List<Rect>>[];
    final tileZoomMatrices = <Matrix4>[];

    for (var i = 0; i < 12; i++) {
      final col = i % _crossAxisCount;
      final row = i ~/ _crossAxisCount;
      final tileRect = Rect.fromLTWH(
        col * (tileW + _crossAxisSpacing),
        row * (tileH + _mainAxisSpacing),
        tileW,
        tileH,
      );
      tileBounds.add(tileRect);
      tileSourceRects.add(
        _calendarWarmupSourceRects(tileRect, yearTileNameStyle, compactWeekdayStyle),
      );
      tileZoomMatrices.add(_zoomMatrixForTile(tileRect, areaSize));
    }

    final destRects = MonthTitleHeader.dayCellRects(
      areaSize,
      fullTitleStyle,
      weekdayLabelStyle: fullWeekdayStyle,
    );

    final weekColumnRects = _weekColumnRects(areaSize, weekWeekdayStyle);
    final monthWeekdayHeaderY = MonthTitleHeader.weekdayHeaderY(
      fullTitleStyle,
    );
    final monthCardRect = Rect.fromLTWH(0, 0, areaSize.width, areaSize.height);
    final weekAreaRect = monthCardRect;
    final monthMorphEventMetrics = calendarMorphEventFrozenMetrics(
      monthCellOuterHeight: destRects.first.height,
    );

    return CalendarLayoutCache._(
      areaSize: areaSize,
      tileBounds: tileBounds,
      tileSourceRects: tileSourceRects,
      tileZoomMatrices: tileZoomMatrices,
      destRects: destRects,
      monthCellRects: destRects,
      weekColumnRects: weekColumnRects,
      monthCardRect: monthCardRect,
      weekAreaRect: weekAreaRect,
      monthWeekdayHeaderY: monthWeekdayHeaderY,
      weekWeekdayHeaderY: calendarWeekHeaderTopPadding,
      monthMorphEventMetrics: monthMorphEventMetrics,
    );
  }

  static List<Rect> _weekColumnRects(Size areaSize, TextStyle weekdayStyle) {
    return CalendarWeekLayoutMetrics.compute(
      areaSize: areaSize,
      weekdayStyle: weekdayStyle,
    ).dayColumnRects;
  }

  static Matrix4 _zoomMatrixForTile(Rect tileRect, Size areaSize) {
    final sx = areaSize.width / tileRect.width;
    final sy = areaSize.height / tileRect.height;
    return Matrix4.identity()
      ..translateByDouble(-tileRect.left * sx, -tileRect.top * sy, 0, 1)
      ..scaleByDouble(sx, sy, 1, 1);
  }
}

// =============================================================================
// CalendarMorphWarmup — placed in AppShell so GPU shaders compile at login
// =============================================================================

/// Renders the calendar morph stack for seven frames immediately after login
/// so the GPU rasteriser compiles all shaders before the user first opens the
/// calendar.  Uses [Opacity] (not [Offstage]) so painting actually occurs.
///
/// Steps 0-2 render with [morphReverse]=false at t = 0.05, 0.20, 0.35.
/// Steps 3-6 render with [morphReverse]=true at t = 0.05, 0.20, 0.35, 0.0.
class CalendarMorphWarmup extends StatefulWidget {
  const CalendarMorphWarmup({super.key});

  @override
  State<CalendarMorphWarmup> createState() => _CalendarMorphWarmupState();
}

class _CalendarMorphWarmupState extends State<CalendarMorphWarmup>
    with SingleTickerProviderStateMixin {
  static const _areaSize = Size(900, 700);
  static const _tileRect = Rect.fromLTWH(16, 120, 200, 148);

  static const _forwardT = [0.05, 0.20, 0.35];
  static const _reverseT = [0.05, 0.20, 0.35, 0.0];

  late final AnimationController _controller;
  bool _done = false;

  // 3 forward paint frames + 4 reverse paint frames.
  int _step = 0;
  bool _morphReverse = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _controller.value = _forwardT.first;
    WidgetsBinding.instance.addPostFrameCallback(_advanceWarmup);
  }

  void _advanceWarmup(Duration _) {
    if (!mounted) return;
    if (_step >= _forwardT.length + _reverseT.length) {
      setState(() => _done = true);
      return;
    }
    if (_step == _forwardT.length) {
      setState(() => _morphReverse = true);
    }
    _controller.value = _step < _forwardT.length
        ? _forwardT[_step]
        : _reverseT[_step - _forwardT.length];
    setState(() {});
    _step++;
    WidgetsBinding.instance.addPostFrameCallback(_advanceWarmup);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static Matrix4 _zoomMatrix(Rect tileRect, Size areaSize) {
    final sx = areaSize.width / tileRect.width;
    final sy = areaSize.height / tileRect.height;
    return Matrix4.identity()
      ..translateByDouble(-tileRect.left * sx, -tileRect.top * sy, 0, 1)
      ..scaleByDouble(sx, sy, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();

    final (compact, full) = _calendarWeekdayMorphStyles(context);
    final (yearName, monthTitle) = _calendarTitleMorphStyles(context);
    final morphMonth = DateTime(DateTime.now().year, 6, 1);
    final dates = monthGridDates(morphMonth, weekStartsMonday: true);
    final sourceRects = _calendarWarmupSourceRects(_tileRect, yearName, compact);
    final destRects = MonthTitleHeader.dayCellRects(
      _areaSize,
      monthTitle,
      weekdayLabelStyle: full,
    );
    final monthMorphEventMetrics = calendarMorphEventFrozenMetrics(
      monthCellOuterHeight: destRects.first.height,
    );

    // For the reverse frames the tween must run zoomed→identity so the GPU
    // compiles the inverted matrix interpolation code path.
    final yearTween = _morphReverse
        ? Matrix4Tween(
            begin: _zoomMatrix(_tileRect, _areaSize),
            end: Matrix4.identity(),
          )
        : Matrix4Tween(
            begin: Matrix4.identity(),
            end: _zoomMatrix(_tileRect, _areaSize),
          );

    // SizedBox.shrink + OverflowBox renders the warmup widget at its real size
    // while occupying zero layout space.  Opacity > 0 ensures actual painting
    // so Skia/Impeller pipeline shaders are compiled on this frame.
    return SizedBox.shrink(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxWidth: _areaSize.width,
        maxHeight: _areaSize.height,
        child: IgnorePointer(
          child: Opacity(
            opacity: 1 / 255,
            child: _MorphAnimationLayer(
              // ValueKey forces a full rebuild when morphReverse flips so that
              // _MorphAnimationLayerState.initState re-runs with the new flag.
              key: ValueKey(_morphReverse),
              controller: _controller,
              yearTween: yearTween,
              sourceRects: sourceRects,
              destRects: destRects,
              morphReverse: _morphReverse,
              tileRect: _tileRect,
              areaSize: _areaSize,
              morphMonth: morphMonth,
              dates: dates,
              weekStartsMonday: true,
              compactWeekdayStyle: compact,
              fullWeekdayStyle: full,
              yearMonthNameStyle: yearName,
              monthTitleStyle: monthTitle,
              yearGrid: CalendarGrid(
                mode: CalendarViewMode.year,
                focused: DateTime(morphMonth.year, 1, 1),
                events: const [],
                indicators: const [],
                weekStartsMonday: true,
                onDayTap: (_) {},
                onMonthTap: (_) {},
                hiddenMonth: _morphReverse ? morphMonth : null,
              ),
              events: const [],
              todoMarkers: const [],
              monthMorphEventMetrics: monthMorphEventMetrics,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Morph animation primitives
// =============================================================================

/// Provides morph progress to descendant [_MorphCell]s.
///
/// [t] drives layout (source → dest rects). [styleT] drives visuals: 0 = compact
/// year tile, 1 = full month view (inverted during month→year reverse).
class _MorphProgress extends InheritedWidget {
  const _MorphProgress({
    required this.t,
    required this.styleT,
    required this.morphReverse,
    required this.dividerColor,
    required this.adjacentColor,
    required this.monthMorphEventMetrics,
    required super.child,
  });

  final double t;
  final double styleT;
  final bool morphReverse;

  /// Pre-computed once per frame so the 42 [_MorphCell]s don't each call
  /// [Theme.of] / allocate a new [Color] on every animation tick.
  final Color dividerColor;
  final Color adjacentColor;

  /// Event-bar metrics indexed by event count — from [CalendarLayoutCache].
  final List<MorphDayEventFrozenMetrics> monthMorphEventMetrics;

  static _MorphProgress of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MorphProgress>()!;

  @override
  bool updateShouldNotify(_MorphProgress old) =>
      old.t != t || old.styleT != styleT || old.morphReverse != morphReverse;
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
    required this.weekStartsMonday,
    required this.compactWeekdayStyle,
    required this.fullWeekdayStyle,
    required this.yearMonthNameStyle,
    required this.monthTitleStyle,
    required this.yearGrid,
    required this.events,
    required this.todoMarkers,
    required this.monthMorphEventMetrics,
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
  final bool weekStartsMonday;
  final TextStyle compactWeekdayStyle;
  final TextStyle fullWeekdayStyle;
  final TextStyle yearMonthNameStyle;
  final TextStyle monthTitleStyle;
  final Widget yearGrid;
  final List<CalendarEvent> events;
  final List<CalendarTodoMarker> todoMarkers;
  final List<MorphDayEventFrozenMetrics> monthMorphEventMetrics;

  @override
  State<_MorphAnimationLayer> createState() => _MorphAnimationLayerState();
}

class _MorphAnimationLayerState extends State<_MorphAnimationLayer> {
  late final List<Widget> _cellChildren;
  late final Widget _yearGridChild;
  late final Matrix4 _yearMatrixBegin;
  late final Matrix4 _yearMatrixEnd;

  /// Mutated in-place each frame — no [Matrix4] allocation during the morph.
  final _yearTransform = Matrix4.identity();
  late final Rect _fullAreaRect;
  late final Rect _sourceTitleRect;
  late final Rect _destTitleRect;
  late final Rect _sourceWeekdayRect;
  late final Rect _destWeekdayRect;
  late final List<WeekdayMorphMetrics> _weekdayMetrics;
  late final String _monthName;
  late final double _navCenterYBegin;
  late final double _navCenterYEnd;

  @override
  void initState() {
    super.initState();
    _yearGridChild = widget.yearGrid;
    _yearMatrixBegin = Matrix4.copy(widget.yearTween.begin!);
    _yearMatrixEnd = Matrix4.copy(widget.yearTween.end!);
    _fullAreaRect = Rect.fromLTWH(
      0,
      0,
      widget.areaSize.width,
      widget.areaSize.height,
    );

    final tileCellRects = widget.morphReverse
        ? widget.destRects
        : widget.sourceRects;
    final monthCellRects = widget.morphReverse
        ? widget.sourceRects
        : widget.destRects;

    _sourceWeekdayRect = MorphWeekdayHeader.rowRectFromDayCells(
      tileCellRects,
      widget.compactWeekdayStyle,
      useSingleLetterLabels: true,
    );
    _destWeekdayRect = MorphWeekdayHeader.rowRectFromDayCells(
      monthCellRects,
      widget.fullWeekdayStyle,
    );

    _monthName = _mmmmFormat.format(widget.morphMonth);

    final yearTitleSize = MonthTitleHeader.measureTitleText(
      widget.yearMonthNameStyle,
      MonthTitleHeader.heightReferenceText,
    );
    final tileHeaderTop = widget.tileRect.top + 6;
    _sourceTitleRect = Rect.fromLTWH(
      widget.tileRect.left + 6,
      tileHeaderTop,
      widget.tileRect.width - 12,
      yearTitleSize.height,
    );
    _destTitleRect = Rect.fromLTWH(
      MonthTitleHeader.cardPadding,
      MonthTitleHeader.cardPadding,
      widget.areaSize.width - MonthTitleHeader.cardPadding * 2,
      MonthTitleHeader.preferredHeight(widget.monthTitleStyle),
    );

    _weekdayMetrics = WeekdayMorphMetrics.columnsFor(
      weekStartsMonday: widget.weekStartsMonday,
      compactStyle: widget.compactWeekdayStyle,
      fullStyle: widget.fullWeekdayStyle,
    );

    _navCenterYBegin = MonthTitleHeader.textVisualCenterDy(
      widget.yearMonthNameStyle,
      _monthName,
    );
    _navCenterYEnd = MonthTitleHeader.textVisualCenterDy(
      widget.monthTitleStyle,
      _monthName,
    );

    _cellChildren = [
      for (var i = 0; i < 42; i++)
        LayoutId(
          id: i,
          child: _MorphCell(
            key: ValueKey(widget.dates[i]),
            date: widget.dates[i],
            month: widget.morphMonth,
            events: widget.dates[i].month == widget.morphMonth.month &&
                    widget.dates[i].year == widget.morphMonth.year
                ? widget.events
                    .where((e) => calendarEventOnDay(e, widget.dates[i]))
                    .toList()
                : const <CalendarEvent>[],
            todoMarkers:
                widget.dates[i].month == widget.morphMonth.month &&
                    widget.dates[i].year == widget.morphMonth.year
                ? calendarTodoMarkersForDay(
                    widget.todoMarkers,
                    widget.dates[i],
                  )
                : const <CalendarTodoMarker>[],
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
            final t = Curves.easeInOutCubic.transform(widget.controller.value);
            final bgRect = widget.morphReverse
                ? Rect.lerp(_fullAreaRect, widget.tileRect, t)!
                : Rect.lerp(widget.tileRect, _fullAreaRect, t)!;
            final titleRect = widget.morphReverse
                ? Rect.lerp(_destTitleRect, _sourceTitleRect, t)!
                : Rect.lerp(_sourceTitleRect, _destTitleRect, t)!;
            final navOpacity = widget.morphReverse ? 1.0 - t : t;
            final navSpread = navOpacity;
            final styleT = widget.morphReverse ? 1.0 - t : t;
            _applyYearTransform(t);

            final weekdayRect = widget.morphReverse
                ? Rect.lerp(_destWeekdayRect, _sourceWeekdayRect, t)!
                : Rect.lerp(_sourceWeekdayRect, _destWeekdayRect, t)!;

            return _MorphProgress(
              t: t,
              styleT: styleT,
              morphReverse: widget.morphReverse,
              dividerColor: Theme.of(context).dividerColor,
              adjacentColor: calendarAdjacentMonthColor(context),
              monthMorphEventMetrics: widget.monthMorphEventMetrics,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Transform(transform: _yearTransform, child: yearGridChild),
                  Positioned(
                    left: bgRect.left,
                    top: bgRect.top,
                    width: bgRect.width,
                    height: bgRect.height,
                    child: Card(
                      margin: EdgeInsets.zero,
                      color: calendarPanelBackgroundColor(context),
                      child: const SizedBox.expand(),
                    ),
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
                    child: MorphMonthTitle(
                      month: widget.morphMonth,
                      monthName: _monthName,
                      styleT: styleT,
                      yearTitleStyle: widget.yearMonthNameStyle,
                      monthTitleStyle: widget.monthTitleStyle,
                      navOpacity: navOpacity,
                      navSpread: navSpread,
                      navCenterY: lerpDouble(
                        _navCenterYBegin,
                        _navCenterYEnd,
                        styleT,
                      ),
                    ),
                  ),
                  Positioned(
                    left: weekdayRect.left,
                    top: weekdayRect.top,
                    width: weekdayRect.width,
                    height: weekdayRect.height,
                    child: MorphWeekdayHeader(
                      columns: _weekdayMetrics,
                      styleT: styleT,
                      compactStyle: widget.compactWeekdayStyle,
                      fullStyle: widget.fullWeekdayStyle,
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
    final count = sourceRects.length;
    for (var i = 0; i < count; i++) {
      final rect = Rect.lerp(sourceRects[i], destRects[i], t)!;
      layoutChild(i, BoxConstraints.tight(rect.size));
      positionChild(i, rect.topLeft);
    }
  }

  @override
  bool shouldRelayout(_MorphLayoutDelegate old) => old.t != t;
}

/// A single calendar day cell that morphs between the compact year-tile style
/// (styleT = 0) and the full month-view style (styleT = 1).
///
/// Layout position/size uses animation [t] via [_MorphLayoutDelegate].
/// Visual properties use [styleT] from [_MorphProgress] so month→year reverse
/// starts at full-month styling and ends at compact year styling.
class _MorphCell extends StatelessWidget {
  const _MorphCell({
    super.key,
    required this.date,
    required this.month,
    required this.events,
    required this.todoMarkers,
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarTodoMarker> todoMarkers;

  static const _compactFontSize = 7.0;
  static const _fullFontSize = 15.0;

  static double _dayFontSize(double styleT) =>
      lerpDouble(_compactFontSize, _fullFontSize, styleT)!;

  /// Matches [CalendarDayNumber] diameter: fontSize + (compact ? 5 : 8).
  static double _dayLayoutDiameter(double fontSize) =>
      fontSize + (fontSize <= 9 ? 5 : 8);

  /// Year-tile day vertical alignment — matches [CalendarDayCell] compact column.
  static Alignment _yearDayAlignment({
    required double cellHeight,
    required double daySize,
    required bool hasEvents,
  }) {
    if (!hasEvents) return Alignment.center;
    const gap = 1.0;
    const dotHeight = 2.0;
    final blockHeight = daySize + gap + dotHeight;
    final blockTop = (cellHeight - blockHeight) / 2;
    final dayCenterY = blockTop + daySize / 2;
    final alignY = ((dayCenterY / cellHeight) * 2 - 1).clamp(-1.0, 1.0);
    return Alignment(0, alignY);
  }

  // Cell margin (creates the gap between adjacent cells).
  static const _compactCellMargin = 0.5; // compact.cellMargin.top
  static const _fullCellMargin = 1.0; // full.cellMargin.top
  // Cell padding (inset inside the border, before the day number).
  static final _compactCellPadding = MonthDayCellStyle.compact.cellPadding;
  static final _fullCellPadding = MonthDayCellStyle.full.cellPadding;

  Widget? _morphTodoOverlay({
    required _MorphProgress progress,
    required double styleT,
    required bool inMonth,
  }) {
    if (!inMonth || todoMarkers.isEmpty) {
      return null;
    }
    final iconProgress = calendarMorphTodoIconProgress(
      morphReverse: progress.morphReverse,
      styleT: styleT,
    );
    if (iconProgress <= 0) return null;
    return Positioned(
      right: 0,
      bottom: 0,
      child: Opacity(
        opacity: iconProgress,
        child: Transform.scale(
          scale: iconProgress,
          alignment: Alignment.bottomRight,
          child: CalendarDayTodoIcons(markers: todoMarkers),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final progress = _MorphProgress.of(context);
    final styleT = progress.styleT;
    // styleT 0 = compact year tile, 1 = full month cell.
    final dayFontSize = _dayFontSize(styleT);
    final cellMargin =
        _compactCellMargin + (_fullCellMargin - _compactCellMargin) * styleT;

    final borderRadius =
        MonthDayCellStyle.compact.borderRadius +
        (MonthDayCellStyle.full.borderRadius -
                MonthDayCellStyle.compact.borderRadius) *
            styleT;

    final inMonth = date.month == month.month;
    final compactBorderAlpha = MonthDayCellStyle.compact.borderOpacity;
    final fullBorderAlpha = inMonth
        ? MonthDayCellStyle.full.borderOpacity
        : calendarAdjacentMonthBorderOpacity;
    // Colors computed once per frame by the AnimatedBuilder and threaded down
    // via _MorphProgress — avoids 42× Theme.of lookups on every animation tick.
    final fullBorderColor =
        inMonth ? progress.dividerColor : progress.adjacentColor;
    final borderAlpha =
        compactBorderAlpha + (fullBorderAlpha - compactBorderAlpha) * styleT;

    return Container(
      margin: EdgeInsets.all(cellMargin),
      decoration: BoxDecoration(
        border: Border.all(
          color: fullBorderColor.withValues(alpha: borderAlpha.clamp(0.0, 1.0)),
        ),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Padding(
          padding: EdgeInsets.lerp(
            _compactCellPadding,
            _fullCellPadding,
            styleT,
          )!,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dayLayoutSize = _dayLayoutDiameter(dayFontSize)
                  .clamp(0.0, constraints.maxHeight);
              final showEvents = events.isNotEmpty && inMonth;
              final yearDotsSettled = MorphDayEventStack.yearDotsSettled(
                morphReverse: progress.morphReverse,
                eventCount: events.length,
                styleT: styleT,
              );
              final layoutDayLayoutSize = _dayLayoutDiameter(_fullFontSize)
                  .clamp(0.0, constraints.maxHeight);
              final compactDaySize = _dayLayoutDiameter(
                MonthDayCellStyle.compact.fontSize,
              ).clamp(0.0, constraints.maxHeight);

              final yearAlignment = _yearDayAlignment(
                cellHeight: constraints.maxHeight,
                daySize: yearDotsSettled ? compactDaySize : dayLayoutSize,
                hasEvents: showEvents,
              );

              final cellAlignment = Alignment.lerp(
                yearAlignment,
                Alignment.topCenter,
                styleT,
              )!;

              if (yearDotsSettled) {
                final todoOverlay = _morphTodoOverlay(
                  progress: progress,
                  styleT: styleT,
                  inMonth: inMonth,
                );
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Align(
                      alignment: yearAlignment,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: CalendarDayNumber(
                              date: date,
                              month: month,
                              fontSize: MonthDayCellStyle.compact.fontSize,
                              mutedWhenAdjacent: !inMonth,
                            ),
                          ),
                          if (inMonth && events.isNotEmpty) ...[
                            const SizedBox(height: 1),
                            CalendarDayEventDots(
                              events: events,
                              dotSize: MonthDayCellStyle.compact.eventDotSize,
                              maxDots: MonthDayCellStyle.compact.maxEventLines,
                            ),
                          ],
                        ],
                      ),
                    ),
                    ?todoOverlay,
                  ],
                );
              }

              final todoOverlay = _morphTodoOverlay(
                progress: progress,
                styleT: styleT,
                inMonth: inMonth,
              );

              return ClipRect(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Align(
                      alignment: cellAlignment,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: CalendarDayNumber(
                          date: date,
                          month: month,
                          fontSize: dayFontSize,
                          mutedWhenAdjacent: !inMonth,
                        ),
                      ),
                    ),
                    if (showEvents)
                      Positioned.fill(
                        child: MorphDayEventStack(
                          events: events,
                          styleT: styleT,
                          inMonth: inMonth,
                          maxWidth: constraints.maxWidth,
                          cellHeight: constraints.maxHeight,
                          dayLayoutSize: dayLayoutSize,
                          layoutDayLayoutSize: layoutDayLayoutSize,
                          morphReverse: progress.morphReverse,
                          frozenMetrics: progress.monthMorphEventMetrics[
                              events.length
                                  .clamp(0, MorphDayEventStack.maxMonthEvents)],
                        ),
                      ),
                    ?todoOverlay,
                  ],
                ),
              );
            },
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
        buttonStyle.textStyle?.resolve(const {}) ?? theme.textTheme.labelLarge;
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
// Month ↔ week morph
// =============================================================================

/// Visual progress for month↔week morph cells (0 = month, 1 = week).
class _WeekMorphProgress extends InheritedWidget {
  const _WeekMorphProgress({
    required this.t,
    required this.monthEntryOpacity,
    required super.child,
  });

  final double t;
  final double monthEntryOpacity;

  static _WeekMorphProgress of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WeekMorphProgress>()!;

  @override
  bool updateShouldNotify(_WeekMorphProgress old) =>
      old.t != t || old.monthEntryOpacity != monthEntryOpacity;
}

class _MonthWeekMorphLayer extends StatefulWidget {
  const _MonthWeekMorphLayer({
    super.key,
    required this.controller,
    required this.morphMonth,
    required this.anchor,
    required this.weekRow,
    required this.monthRowRects,
    required this.weekColumnRects,
    required this.monthCardRect,
    required this.weekAreaRect,
    required this.monthWeekdayHeaderY,
    required this.weekWeekdayHeaderY,
    required this.areaSize,
    required this.weekStartsMonday,
    required this.monthWeekdayStyle,
    required this.weekWeekdayStyle,
    required this.monthTitleStyle,
    required this.events,
    required this.indicators,
    required this.todoMarkers,
    required this.inactiveMonthRows,
    required this.weekTimelineScrollController,
    required this.weekTimelineScrollOffset,
    required this.weekMorphForward,
    required this.weekStart,
  });

  final AnimationController controller;
  final DateTime morphMonth;
  final DateTime anchor;
  final int weekRow;
  final List<Rect> monthRowRects;
  final List<Rect> weekColumnRects;
  final Rect monthCardRect;
  final Rect weekAreaRect;
  final double monthWeekdayHeaderY;
  final double weekWeekdayHeaderY;
  final Size areaSize;
  final bool weekStartsMonday;
  final TextStyle monthWeekdayStyle;
  final TextStyle weekWeekdayStyle;
  final TextStyle monthTitleStyle;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final List<CalendarTodoMarker> todoMarkers;
  final Widget inactiveMonthRows;
  final ScrollController weekTimelineScrollController;
  final double weekTimelineScrollOffset;
  final bool weekMorphForward;
  final DateTime weekStart;

  @override
  State<_MonthWeekMorphLayer> createState() => _MonthWeekMorphLayerState();
}

class _MonthWeekMorphLayerState extends State<_MonthWeekMorphLayer> {
  late final List<Widget> _cellChildren;
  late final List<DateTime> _weekDates;
  late final String _monthTitleLabel;
  late final double _monthTitleHeight;
  late final Widget _inactiveMonthChild;
  late final double _frozenEntryLayoutHeight;

  @override
  void initState() {
    super.initState();
    final dates = monthGridDates(
      widget.morphMonth,
      weekStartsMonday: widget.weekStartsMonday,
    );
    _weekDates = dates.sublist(
      widget.weekRow * 7,
      widget.weekRow * 7 + 7,
    );
    _monthTitleLabel = _mmmmFormat.format(widget.morphMonth);
    _monthTitleHeight = MonthTitleHeader.preferredHeight(widget.monthTitleStyle);
    _inactiveMonthChild = widget.inactiveMonthRows;
    _frozenEntryLayoutHeight = calendarMorphMonthInnerCellHeight(
      widget.monthRowRects.first.height,
    );

    _cellChildren = [
      for (var i = 0; i < 7; i++)
        LayoutId(
          id: i,
          child: _MonthWeekMorphCell(
            key: ValueKey(_weekDates[i]),
            date: _weekDates[i],
            month: widget.morphMonth,
            events: widget.events,
            indicators: widget.indicators,
            todoMarkers: widget.todoMarkers,
            frozenEntryLayoutHeight: _frozenEntryLayoutHeight,
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: widget.controller,
          child: _inactiveMonthChild,
          builder: (context, inactiveMonthChild) {
            final t = Curves.easeInOutCubic.transform(widget.controller.value);
            final monthFade = (1.0 - t).clamp(0.0, 1.0);
            final headerY = lerpDouble(
              widget.monthWeekdayHeaderY,
              widget.weekWeekdayHeaderY,
              t,
            )!;
            final weekdayLabelHeight = max(
              WeekdayHeaderRow.labelHeight(widget.monthWeekdayStyle),
              WeekdayHeaderRow.labelHeight(widget.weekWeekdayStyle),
            );
            final divider = Theme.of(context).dividerColor;
            final morphBorderRects = calendarWeekMorphBorderedDayColumnRects(
              monthRowRects: widget.monthRowRects,
              weekColumnRects: widget.weekColumnRects,
              t: t,
            );
            final morphBorderRadius = calendarWeekMorphBorderRadius(t);
            final weekChromeOpacity =
                Curves.easeInOut.transform(t.clamp(0.0, 1.0));
            final monthEntryOpacity = (1.0 - t).clamp(0.0, 1.0);
            final dayAreaTop = Rect.lerp(
              widget.monthRowRects.first,
              widget.weekColumnRects.first,
              t,
            )!.top;
            final onSurfaceVariant =
                Theme.of(context).colorScheme.onSurfaceVariant;
            final hourClipRects = morphBorderRects
                .map(
                  (rect) => rect.shift(
                    Offset(-MonthTitleHeader.cardPadding, -dayAreaTop),
                  ),
                )
                .toList();

            return _WeekMorphProgress(
              t: t,
              monthEntryOpacity: monthEntryOpacity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Constant 60% panel background for month and week views.
                  Positioned.fromRect(
                    rect: widget.monthCardRect,
                    child: Card(
                      margin: EdgeInsets.zero,
                      color: calendarPanelBackgroundColor(context),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // Inactive month rows fade out during month→week morph.
                  Opacity(
                    opacity: monthFade,
                    child: inactiveMonthChild!,
                  ),
                  // Month title fades out beneath morph cells as they expand upward.
                  Positioned(
                    left: MonthTitleHeader.cardPadding,
                    right: MonthTitleHeader.cardPadding,
                    top: MonthTitleHeader.cardPadding,
                    height: _monthTitleHeight,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Opacity(
                        opacity: monthFade,
                        child: Text(
                          _monthTitleLabel,
                          style: widget.monthTitleStyle,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          textHeightBehavior:
                              MonthTitleHeader.titleTextHeightBehavior,
                        ),
                      ),
                    ),
                  ),
                  // Morphing active week row (painted over fading month title).
                  CustomMultiChildLayout(
                    delegate: _MorphLayoutDelegate(
                      sourceRects: widget.monthRowRects,
                      destRects: widget.weekColumnRects,
                      t: t,
                    ),
                    children: _cellChildren,
                  ),
                  // Shared border painter — same stroke as the live week view.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: CustomPaint(
                          painter: CalendarWeekDayColumnBorderPainter(
                            borderedRects: morphBorderRects,
                            color: divider,
                            borderRadius: morphBorderRadius,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Hour lines fade in during month→week (mirrored fade-out via overlay).
                  if (widget.weekMorphForward)
                    Positioned(
                      left: MonthTitleHeader.cardPadding,
                      right: MonthTitleHeader.cardPadding,
                      top: dayAreaTop,
                      bottom: 0,
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: widget.weekTimelineScrollController,
                          builder: (context, _) {
                            final allDayShelfHeight =
                                calendarWeekAllDayShelfHeightFor(
                              events: widget.events,
                              weekDays: _weekDates,
                            );
                            final scrollOffset =
                                calendarWeekEffectiveScrollOffset(
                              widget.weekTimelineScrollController,
                              widget.weekTimelineScrollOffset,
                            );
                            return CustomPaint(
                              painter: CalendarWeekTimeGridPainter(
                                scrollOffset: scrollOffset,
                                allDayShelfHeight: allDayShelfHeight,
                                borderedClipRects: hourClipRects,
                                borderRadius: morphBorderRadius,
                                lineColor: divider.withValues(alpha: 0.45),
                                labelColor: onSurfaceVariant,
                                hourLabelBuilder: calendarWeekHourLabel,
                                lineOpacity: weekChromeOpacity,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  // Week timeline fades out during week→month (mirrors month→week fade-in).
                  if (!widget.weekMorphForward)
                    Positioned(
                      left: 0,
                      right: 0,
                      top:
                          headerY +
                          weekdayLabelHeight +
                          calendarWeekHeaderGap +
                          calendarWeekDayColumnTopInset,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: weekChromeOpacity,
                          child: CalendarWeekTimeline(
                            weekStart: widget.weekStart,
                            events: widget.events,
                            todoMarkers: widget.todoMarkers,
                            weekStartsMonday: widget.weekStartsMonday,
                            initialScrollOffset: widget.weekTimelineScrollOffset,
                            showWeekdayHeader: false,
                            entryFadeEnabled: false,
                            interactive: false,
                            onEventTap: (_) {},
                            onTodoTap: (_) {},
                            onSlotTap: (_, _) {},
                          ),
                        ),
                      ),
                    ),
                  // Weekday headers slide between month and week Y — full labels both ends.
                  Positioned(
                    left: MonthTitleHeader.cardPadding,
                    right: MonthTitleHeader.cardPadding,
                    top: headerY,
                    height: weekdayLabelHeight,
                    child: WeekdayHeaderRow(
                      weekStartsMonday: widget.weekStartsMonday,
                      labelStyle: widget.weekWeekdayStyle,
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

class _MonthWeekMorphCell extends StatelessWidget {
  const _MonthWeekMorphCell({
    super.key,
    required this.date,
    required this.month,
    required this.events,
    required this.indicators,
    required this.todoMarkers,
    required this.frozenEntryLayoutHeight,
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final List<CalendarTodoMarker> todoMarkers;
  final double frozenEntryLayoutHeight;

  @override
  Widget build(BuildContext context) {
    final t = _WeekMorphProgress.of(context).t;
    final monthStyle = MonthDayCellStyle.full;

    final fontSize = lerpDouble(monthStyle.fontSize, 13, t)!;
    final borderRadius = monthStyle.borderRadius +
        (12 - monthStyle.borderRadius) * t;
    final cellMargin = lerpDouble(
      monthStyle.cellMargin.top,
      1,
      t,
    )!;
    final cellPadding = EdgeInsets.lerp(
      monthStyle.cellPadding,
      const EdgeInsets.all(4),
      t,
    )!;

    final inMonth = date.month == month.month;
    final baseBorderAlpha = inMonth
        ? monthStyle.borderOpacity
        : lerpDouble(
            calendarAdjacentMonthBorderOpacity,
            monthStyle.borderOpacity,
            Curves.easeOutCubic.transform(t),
          )!;
    // Cell borders fade out as the shared morph border painter takes over.
    final borderAlpha = (1.0 - t) * baseBorderAlpha;

    final dayEvents = inMonth
        ? events.where((e) => calendarEventOnDay(e, date)).toList()
        : const <CalendarEvent>[];
    final dayIndicators = indicators
        .where((i) => calendarSameDay(i.day, date))
        .take(3)
        .toList();
    final dayTodos = inMonth
        ? calendarTodoMarkersForDay(todoMarkers, date)
        : const <CalendarTodoMarker>[];

    final progress = _WeekMorphProgress.of(context);

    return CalendarDayCell(
      date: date,
      month: month,
      events: dayEvents,
      indicators: dayIndicators,
      todoMarkers: dayTodos,
      showTodoIcons: false,
      hideEntries: false,
      entryOpacity: progress.monthEntryOpacity,
      dayNumberOpacity: (1.0 - t).clamp(0.0, 1.0),
      frozenEntryLayoutHeight: frozenEntryLayoutHeight,
      adjacentTextT: inMonth ? null : t,
      adjacentBorderT: inMonth ? null : Curves.easeOutCubic.transform(t),
      style: MonthDayCellStyle(
        fontSize: fontSize,
        borderRadius: borderRadius,
        cellPadding: cellPadding,
        cellMargin: EdgeInsets.all(cellMargin),
        maxEventLines: monthStyle.maxEventLines,
        dotSize: monthStyle.dotSize,
        eventFontSize: monthStyle.eventFontSize,
        borderOpacity: borderAlpha,
      ),
    );
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

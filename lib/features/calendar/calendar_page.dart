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
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/event_editor_dialog.dart';

// Font size for the month name title in the full month view.
// Must stay in sync with _MonthGrid's title fontSize in calendar_grid.dart.
const _kMonthTitleFontSize = 36.0;

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage>
    with SingleTickerProviderStateMixin {
  CalendarViewMode _mode = CalendarViewMode.year;
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

  // Morph state — populated just before the animation starts.
  List<Rect>? _morphSourceRects;
  List<Rect>? _morphDestRects;
  DateTime? _morphMonth;
  // Tile bounds (area-local) and area size captured at tap time — used to
  // position the morphing card background and month title overlay.
  Rect? _morphTileRect;
  Size? _morphAreaSize;

  static const _zoomDuration = Duration(milliseconds: 600);

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
    _zoomController?.stop();
    setState(() {
      _isZooming = false;
      _morphSourceRects = null;
      _morphDestRects = null;
      _morphMonth = null;
      _morphTileRect = null;
      _morphAreaSize = null;
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
    setState(() {
      _isZooming = false;
      _morphSourceRects = null;
      _morphDestRects = null;
      _morphMonth = null;
      _morphTileRect = null;
      _morphAreaSize = null;
      _zoomController?.stop();
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

    _zoomController ??=
        AnimationController(vsync: this, duration: _zoomDuration);
    _zoomController!.stop();

    // Capture tile and area geometry for the background/title overlay lerp.
    final morphTileRect =
        Rect.fromLTWH(tileOrigin.dx, tileOrigin.dy, tileW, tileH);
    final morphAreaSize = Size(areaW, areaH);

    // Enter the measurement phase: show the normal year grid (visible) and
    // an Offstage full-month grid (laid out but not painted) so we can
    // measure the destination cell positions on the next frame.
    setState(() {
      _mode = CalendarViewMode.month;
      _focused = month;
      _dayViewDate = null;
      _isZooming = true;
      _morphSourceRects = sourceRects;
      _morphDestRects = null;
      _morphMonth = month;
      _morphTileRect = morphTileRect;
      _morphAreaSize = morphAreaSize;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final destRects = _computeDestRects();
      if (destRects == null) {
        // Measurement failed — abort gracefully.
        setState(() => _isZooming = false);
        return;
      }
      // Dest rects are ready; trigger the animation phase rendering.
      setState(() { _morphDestRects = destRects; });

      // Start the controller one frame later so the animation layer is built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _zoomController!.forward(from: 0).then((_) {
          if (mounted) setState(() => _isZooming = false);
        });
      });
    });
  }

  void _onViewModeSelectionChanged(Set<CalendarViewMode> selection) {
    final next = selection.first;
    setState(() {
      _isZooming = false;
      _morphSourceRects = null;
      _morphDestRects = null;
      _morphMonth = null;
      _morphTileRect = null;
      _morphAreaSize = null;
      _mode = next;
      _dayViewDate = null;
      if (next == CalendarViewMode.year) {
        _focused = DateTime(_focused.year, 1, 1);
      }
    });
    _zoomController?.stop();
    _zoomController?.reset();
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
    final Widget label;
    if (_mode == CalendarViewMode.month) {
      label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(DateFormat.MMMM().format(_focused), style: titleStyle),
          Text(' ${_focused.year}', style: titleStyle),
        ],
      );
    } else {
      label = Text(_headerLabel(weekStartsMonday), style: titleStyle);
    }
    return _buildFocusHeaderControls(
      weekStartsMonday: weekStartsMonday,
      label: label,
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
    );
  }

  Widget _buildMainCalendar({
    required List<CalendarEvent> events,
    required List<CalendarDayIndicator> indicators,
    required bool weekStartsMonday,
  }) {
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

      // ---- Measurement phase ------------------------------------------------
      // Dest rects have not been computed yet.  Render the normal year grid
      // so the user sees no visual change, while the Offstage month grid is
      // laid out silently in order to measure its cell positions.
      if (_morphDestRects == null) {
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _calendarGrid(
                events: events,
                indicators: indicators,
                weekStartsMonday: weekStartsMonday,
                mode: CalendarViewMode.year,
                focused: DateTime(_focused.year, 1, 1),
              ),
              // Laid out but never painted — used only for measurement.
              Offstage(
                offstage: true,
                child: _calendarGrid(
                  events: events,
                  indicators: indicators,
                  weekStartsMonday: weekStartsMonday,
                  mode: CalendarViewMode.month,
                  focused: _focused,
                  monthDayGridKey: _fullMonthDayGridKey,
                ),
              ),
            ],
          ),
        );
      }

      // ---- Animation phase --------------------------------------------------
      // Bifurcated render — four layers in z-order:
      //
      //   Stack
      //   ├── [z=0] Transform → YearGrid with hole (11 months zoom away)
      //   ├── [z=1] Positioned card background  (lerps tile → full area)
      //   ├── [z=2] CustomMultiChildLayout → 42 MorphCells (Rect.lerp)
      //   └── [z=3] Positioned month title      (lerps tile title → full title)
      //
      final destRects = _morphDestRects!;
      final fullAreaRect = Rect.fromLTWH(0, 0, areaSize.width, areaSize.height);
      final dates =
          monthGridDates(morphMonth, weekStartsMonday: weekStartsMonday);

      // Source title rect: sits above the source day grid, inside the tile.
      final sourceTitleTop = tileRect.top + 8;
      final sourceTitleRect = Rect.fromLTWH(
        tileRect.left + 8,
        sourceTitleTop,
        tileRect.width - 16,
        (sourceRects[0].top - sourceTitleTop - 4).clamp(4.0, double.infinity),
      );

      // Dest title rect: sits above the dest day grid, inside the card padding.
      final destTitleRect = Rect.fromLTWH(
        8,
        8,
        areaSize.width - 16,
        (destRects[0].top - 12).clamp(8.0, double.infinity),
      );

      // Pre-build static widgets that are invariant across animation ticks.
      // Hoisting them out of the builder avoids re-allocating objects on every
      // frame; only the Positioned bounds change per tick, not the children.
      final cardWidget = Card(
        margin: EdgeInsets.zero,
        child: const SizedBox.expand(),
      );
      final titleWidget = FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          DateFormat.MMMM().format(morphMonth),
          style: Theme.of(context).textTheme.titleSmall!.copyWith(
            fontSize: _kMonthTitleFontSize,
          ),
          textAlign: TextAlign.center,
        ),
      );

      return ClipRect(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: controller,
            // RepaintBoundary caches the year grid as a GPU raster so the
            // Transform matrix change each tick is a cheap compositing op
            // rather than a full repaint of the 462-cell grid.
            child: RepaintBoundary(
              child: IgnorePointer(
                child: _calendarGrid(
                  events: events,
                  indicators: indicators,
                  weekStartsMonday: weekStartsMonday,
                  mode: CalendarViewMode.year,
                  focused: DateTime(morphMonth.year, 1, 1),
                  hiddenMonth: morphMonth,
                ),
              ),
            ),
            builder: (context, yearGridChild) {
              final t = Curves.easeInOutCubic.transform(controller.value);

              // ---- Lerped geometry ----
              final bgRect = Rect.lerp(tileRect, fullAreaRect, t)!;
              final titleRect = Rect.lerp(sourceTitleRect, destTitleRect, t)!;

              return Stack(
                fit: StackFit.expand,
                children: [
                  // z=0 Background: year grid minus the target month, zooming.
                  Transform(
                    transform: yearTween.transform(t),
                    child: yearGridChild,
                  ),
                  // z=1 Card background that grows from tile → full area.
                  // Uses the real Card widget so its corner radius, surface
                  // colour and border stay consistent with the year tiles and
                  // the final month-view card throughout the entire animation.
                  // It lives outside the Transform, so its border is never
                  // scaled or distorted.
                  Positioned(
                    left: bgRect.left,
                    top: bgRect.top,
                    width: bgRect.width,
                    height: bgRect.height,
                    child: cardWidget,
                  ),
                  // z=2 Foreground: 42 day cells morphing from mini → full.
                  CustomMultiChildLayout(
                    delegate: _MorphLayoutDelegate(
                      sourceRects: sourceRects,
                      destRects: destRects,
                      t: t,
                    ),
                    children: [
                      for (var i = 0; i < 42; i++)
                        LayoutId(
                          id: i,
                          child: _MorphCell(
                            date: dates[i],
                            month: morphMonth,
                            t: t,
                          ),
                        ),
                    ],
                  ),
                  // z=3 Month name title morphing from tile header → full header.
                  Positioned(
                    left: titleRect.left,
                    top: titleRect.top,
                    width: titleRect.width,
                    height: titleRect.height,
                    child: titleWidget,
                  ),
                ],
              );
            },
          ),
        ),
      );
    }

    return _calendarGrid(
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
      mode: _mode,
      focused: _mode == CalendarViewMode.year
          ? DateTime(_focused.year, 1, 1)
          : _focused,
    );
  }

  @override
  Widget build(BuildContext context) {
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

// =============================================================================
// Morph animation primitives
// =============================================================================

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
    required this.date,
    required this.month,
    required this.t,
  });

  final DateTime date;
  final DateTime month;
  final double t;

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
                // RepaintBoundary caches each day number circle as a GPU
                // layer.  Transform.scale then composites it without
                // repainting, since the content never changes mid-animation.
                child: RepaintBoundary(
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

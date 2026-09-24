// Events through the month↔week morph: each one is dragged from its month
// pill to its week block — never fading out and back in — along the same path
// in both directions, and the live view on the far side of each handoff picks
// it up exactly where the morph left it.

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';
import 'package:voyager/features/calendar/calendar_week_timeline.dart';

import 'fakes/fake_weather_api_client.dart';

final _boundaryKey = GlobalKey();

/// Two months back: far enough that today's week never reaches into it, so
/// the morph opens the last viewed week rather than today's.
final _month = DateTime(DateTime.now().year, DateTime.now().month - 2, 1);

/// The week the morph opens: the one holding the 8th, which always lies
/// wholly inside its month (week starts Monday by default) — every column
/// has a month cell to carry its events from.
final _week = [
  for (var i = 0; i < 7; i++)
    DateTime(
      _month.year,
      _month.month,
      calendarWeekStart(DateTime(_month.year, _month.month, 8), true).day + i,
    ),
];

DateTime _at(int day, int hour) =>
    DateTime(_week[day].year, _week[day].month, _week[day].day, hour);

/// One of each shape the morph has to carry, every one in today's week.
List<CalendarEvent> _events() {
  final now = utcNow();
  CalendarEvent event(
    String id,
    DateTime start,
    DateTime end, {
    bool fullDay = true,
    int color = 0xFFD03030,
  }) => CalendarEvent(
    id: id,
    calendarId: legacyCalendarId,
    title: id,
    start: start,
    end: end,
    isFullDay: fullDay,
    colorValue: color,
    createdAt: now,
    updatedAt: now,
  );
  return [
    // Single all-day, onto the shelf.
    event('allday', _at(1, 0), _at(1, 23).add(const Duration(minutes: 59))),
    // All-day across three days: three segments that must travel together.
    event(
      'span',
      _at(2, 0),
      _at(4, 23).add(const Duration(minutes: 59)),
      color: 0xFF3050D0,
    ),
    // Timed, landing inside the week view's opening scroll window.
    event('timed', _at(3, 10), _at(3, 11), fullDay: false, color: 0xFF30A030),
    // Timed, landing above the scroll window: slides off and is clipped.
    event('early', _at(0, 2), _at(0, 3), fullDay: false, color: 0xFFA030A0),
    // Timed across midnight: the week view shelves it with the all-day ones.
    event(
      'overnight',
      _at(5, 22),
      _at(6, 1),
      fullDay: false,
      color: 0xFFD0A030,
    ),
    // More than a month cell shows: the rest sit behind "+N" in month view.
    for (var i = 0; i < 6; i++)
      event(
        'crowd$i',
        _at(6, 0),
        _at(6, 23).add(const Duration(minutes: 59)),
        color: 0xFF208080,
      ),
  ];
}

Future<void> _pumpCalendar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftCalendarRepository(db);
  final now = utcNow();
  await repo.upsertCalendar(
    Calendar(
      id: legacyCalendarId,
      name: 'Calendar',
      createdAt: now,
      updatedAt: now,
    ),
  );
  for (final event in _events()) {
    await repo.upsertEvent(event);
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(calendarsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(key: _boundaryKey, child: const CalendarPage()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));

  // Back to [_month], into its first week, on to [_week], and back out, so
  // month view remembers [_week] as the one to open.
  for (var i = 0; i < 2; i++) {
    await tester.tap(find.byIcon(PhosphorIconsRegular.caretLeft).first);
    await _settle(tester);
  }
  await tester.tap(find.text('Week'));
  await _settle(tester);
  await tester.tap(find.byIcon(PhosphorIconsRegular.caretRight).first);
  await _settle(tester);
  await tester.tap(find.text('Month'));
  await _settle(tester);
}

String _key(String id, int column) => '$id@$column';

/// Plays a view switch through to its handoff. Frame by frame: a ticker's
/// first frame only records its start time, so one long pump wouldn't move it.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(seconds: 1));
}

/// Every event segment the live month view is showing in today's week row,
/// as the pill the eye sees: the bar's height, clipped to its cell's sides.
Map<String, Rect> _monthPills(WidgetTester tester) {
  final pills = <String, Rect>{};
  for (final element in find.byType(CalendarDayEventBar).evaluate()) {
    final bar = element.widget as CalendarDayEventBar;
    final column = _week.indexWhere((d) => calendarSameDay(d, bar.date));
    if (column < 0) continue;
    final cell = find.ancestor(
      of: find.byWidget(bar),
      matching: find.byType(CalendarDayCell),
    );
    final clip = tester.getRect(cell.first).deflate(2);
    final rect = tester.getRect(find.byWidget(bar));
    pills[_key(bar.event.id, column)] = Rect.fromLTRB(
      clip.left,
      rect.top,
      clip.right,
      rect.bottom,
    );
  }
  return pills;
}

/// Every event block the live week view lays out, at its full painted width
/// (bridged segments reach across the gap between columns). Blocks scrolled
/// out of the timed viewport are included, where they sit unclipped.
Map<String, Rect> _weekBlocks(WidgetTester tester) {
  final blocks = <String, Rect>{};
  for (final element in find.byType(CalendarWeekEventBlock).evaluate()) {
    final block = element.widget as CalendarWeekEventBlock;
    final column = _week.indexWhere((d) => calendarSameDay(d, block.day!));
    final fill = find.descendant(
      of: find.byWidget(block),
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.decoration != null,
      ),
    );
    blocks[_key(block.event.id, column)] = tester.getRect(fill.first);
  }
  return blocks;
}

Finder _morphPill(String key) => find.byKey(ValueKey('week-morph-$key'));

double _pillOpacity(WidgetTester tester, String key) => tester
    .widget<Opacity>(
      find.ancestor(of: _morphPill(key), matching: find.byType(Opacity)).first,
    )
    .opacity;

/// Morph progress, read off the morphing cell of [column]: it is laid out at
/// exactly lerp(month cell, week column, t).
double _progress(
  WidgetTester tester,
  int column,
  Rect monthCell,
  Rect weekColumn,
) {
  final cell = tester.getRect(find.byKey(ValueKey(_week[column])));
  return (cell.height - monthCell.height) /
      (weekColumn.height - monthCell.height);
}

Future<ui.Image> _capture(WidgetTester tester) async {
  final boundary =
      tester.renderObject(find.byKey(_boundaryKey)) as RenderRepaintBoundary;
  return (await tester.runAsync(() => boundary.toImage()))!;
}

Future<Color> _pixel(WidgetTester tester, ui.Image image, Offset at) async {
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final i = (at.dy.round() * image.width + at.dx.round()) * 4;
  return Color.fromARGB(
    255,
    bytes.getUint8(i),
    bytes.getUint8(i + 1),
    bytes.getUint8(i + 2),
  );
}

bool _near(Color a, int argb) {
  final b = Color(argb);
  return (a.r - b.r).abs() < 0.08 &&
      (a.g - b.g).abs() < 0.08 &&
      (a.b - b.b).abs() < 0.08;
}

void _expectRect(Rect actual, Rect expected, String reason) {
  for (final (a, e, edge) in [
    (actual.left, expected.left, 'left'),
    (actual.top, expected.top, 'top'),
    (actual.right, expected.right, 'right'),
    (actual.bottom, expected.bottom, 'bottom'),
  ]) {
    expect(a, moreOrLessEquals(e, epsilon: 0.75), reason: '$reason ($edge)');
  }
}

/// Plays the switch to [label] frame by frame and checks every event entry
/// against where [monthPills] and [weekBlocks] say its two ends are.
///
/// The per-frame rule is the same in both directions — a carried pill is at
/// lerp(month, week, t), fully opaque — so passing it both ways means the two
/// animations trace one path, mirrored.
Future<void> _playAndCheck(
  WidgetTester tester, {
  required String label,
  required Map<String, Rect> monthPills,
  required Map<String, Rect> weekBlocks,
  required List<Rect> monthCells,
  required List<Rect> weekColumns,
}) async {
  final carried = {
    for (final key in monthPills.keys)
      if (weekBlocks.containsKey(key)) key,
  };
  final fadeIn = weekBlocks.keys.toSet().difference(monthPills.keys.toSet());
  final fades = <String, List<double>>{};
  final seenT = <double>[];

  await tester.tap(find.text(label));
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump(
      frame == 0 ? Duration.zero : const Duration(milliseconds: 16),
    );
    if (find.byKey(ValueKey(_week[0])).evaluate().isEmpty) {
      if (seenT.isEmpty) continue;
      break; // Handed off.
    }
    // The live week grid fading out behind week→month must not draw its own
    // copy. (Month→week keeps one mounted but invisible, for its scroll.)
    if (label == 'Month') {
      expect(find.byType(CalendarWeekEventBlock), findsNothing);
    }

    for (final key in carried) {
      final column = int.parse(key.split('@').last);
      final t = _progress(
        tester,
        column,
        monthCells[column],
        weekColumns[column],
      );
      if (column == 0) seenT.add(t);
      expect(_morphPill(key), findsOneWidget, reason: '$key at t=$t');
      expect(_pillOpacity(tester, key), 1.0, reason: '$key at t=$t');
      _expectRect(
        tester.getRect(_morphPill(key)),
        Rect.lerp(monthPills[key], weekBlocks[key], t)!,
        '$key at t=$t',
      );
    }
    for (final key in fadeIn) {
      if (_morphPill(key).evaluate().isEmpty) continue;
      _expectRect(tester.getRect(_morphPill(key)), weekBlocks[key]!, key);
      (fades[key] ??= []).add(_pillOpacity(tester, key));
    }
  }
  // Starts at its own end of the morph and plays it through.
  final forward = label == 'Week';
  expect(seenT.first, closeTo(forward ? 0 : 1, 1e-6));
  expect(seenT.length, greaterThan(20));
  // Entries with no month pill fade at their week spot — in on the way to
  // week, out on the way back.
  expect(fades.keys.toSet(), fadeIn);
  for (final MapEntry(:key, value: series) in fades.entries) {
    for (var i = 1; i < series.length; i++) {
      expect(
        forward ? series[i] >= series[i - 1] : series[i] <= series[i - 1],
        isTrue,
        reason: '$key fade: $series',
      );
    }
    expect(forward ? series.last : series.first, greaterThan(0.9), reason: key);
  }
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('month → week → month drags every event along one path', (
    tester,
  ) async {
    await _pumpCalendar(tester);

    final monthPills = _monthPills(tester);
    final monthCells = [
      for (final day in _week)
        tester.getRect(
          find.byWidgetPredicate(
            (w) => w is CalendarDayCell && calendarSameDay(w.date, day),
          ),
        ),
    ];
    // Month view carries the shapes it can: the shelf, a spanning event,
    // both timed ones, and four of the crowd.
    for (final id in ['allday', 'span', 'timed', 'early', 'overnight']) {
      expect(
        monthPills.keys.where((k) => k.startsWith('$id@')),
        isNotEmpty,
        reason: id,
      );
    }

    // Measure the week end on a throwaway trip, so the checked trips can be
    // compared against it.
    await tester.tap(find.text('Week'));
    await _settle(tester);
    final weekBlocks = _weekBlocks(tester);
    final weekColumns = [
      for (var i = 0; i < 7; i++) _weekColumnRect(tester, i),
    ];
    await tester.tap(find.text('Month'));
    await _settle(tester);
    expect(_monthPills(tester), monthPills);

    // Six crowd events, fewer month lanes: some have no month end and fade.
    final crowdInMonth = monthPills.keys.where((k) => k.startsWith('crowd'));
    final crowdInWeek = weekBlocks.keys.where((k) => k.startsWith('crowd'));
    expect(crowdInWeek.length, 6);
    expect(crowdInMonth.length, lessThan(6));

    await _playAndCheck(
      tester,
      label: 'Week',
      monthPills: monthPills,
      weekBlocks: weekBlocks,
      monthCells: monthCells,
      weekColumns: weekColumns,
    );
    expect(_weekBlocks(tester), weekBlocks);

    await _playAndCheck(
      tester,
      label: 'Month',
      monthPills: monthPills,
      weekBlocks: weekBlocks,
      monthCells: monthCells,
      weekColumns: weekColumns,
    );
    expect(_monthPills(tester), monthPills);
  });

  testWidgets('a carried pill stays painted through the whole morph', (
    tester,
  ) async {
    await _pumpCalendar(tester);
    for (final label in ['Week', 'Month']) {
      await tester.tap(find.text(label));
      var frames = 0;
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final pill = _morphPill(_key('allday', 1));
        if (pill.evaluate().isEmpty) continue;
        frames++;
        final image = await _capture(tester);
        final center = tester.getRect(pill).center;
        expect(
          _near(await _pixel(tester, image, center), 0xFFD03030),
          isTrue,
          reason: '$label frame $frame',
        );
      }
      expect(frames, greaterThan(20));
      await tester.pump(const Duration(seconds: 1));
    }
  });

  testWidgets('the week view does not fade its entries in again after the '
      'morph, but still fades them in on a week change', (tester) async {
    await _pumpCalendar(tester);
    await tester.tap(find.text('Week'));
    FadeTransition entryFade() => tester.widget<FadeTransition>(
      find
          .descendant(
            of: find.byType(CalendarWeekTimeline),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(ValueKey(_week[0])).evaluate().isNotEmpty) continue;
      if (find.byType(CalendarWeekTimeline).evaluate().isEmpty) continue;
      expect(entryFade().opacity.value, 1.0, reason: 'frame $frame');
    }

    await tester.tap(find.byIcon(PhosphorIconsRegular.caretRight).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(entryFade().opacity.value, lessThan(1.0));
    await tester.pump(const Duration(seconds: 1));
    expect(entryFade().opacity.value, 1.0);
  });

  testWidgets('week → year keeps the week grid\'s own events fading out, '
      'since that chained morph carries none', (tester) async {
    await _pumpCalendar(tester);
    await tester.tap(find.text('Week'));
    await _settle(tester);
    await tester.tap(find.text('Year'));
    var morphFrames = 0;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(ValueKey(_week[0])).evaluate().isEmpty) continue;
      morphFrames++;
      expect(find.byType(CalendarWeekEventBlock), findsWidgets);
      expect(_morphPill(_key('allday', 1)), findsNothing);
    }
    expect(morphFrames, greaterThan(0));
    await _settle(tester);
  });

  testWidgets('a timed event headed off-screen is clipped to its column', (
    tester,
  ) async {
    await _pumpCalendar(tester);
    await tester.tap(find.text('Week'));
    Rect? lastPill;
    Rect? lastClip;
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final pill = _morphPill(_key('early', 0));
      if (pill.evaluate().isEmpty) continue;
      lastPill = tester.getRect(pill);
      lastClip = tester.getRect(
        find.ancestor(of: pill, matching: find.byType(ClipRRect)).first,
      );
    }
    // By the last morph frame the block sits above the column's viewport,
    // wholly outside the clip, as it will once the live view takes over.
    expect(lastPill!.bottom, lessThan(lastClip!.top));
  });
}

/// The live week view's timed day column [i], as the morph's week end: its
/// border rect, re-inflated by the column margin.
Rect _weekColumnRect(WidgetTester tester, int i) {
  final timeline = tester.getRect(find.byType(CalendarWeekTimeline));
  final weekdayStyle = calendarWeekdayLabelStyle(
    tester.element(find.byType(CalendarWeekTimeline)),
    fontSize: calendarWeekWeekdayFontSize,
  );
  final metrics = CalendarWeekLayoutMetrics.compute(
    areaSize: timeline.size,
    weekdayStyle: weekdayStyle,
    allDayShelfHeight: calendarWeekAllDayShelfHeightFor(
      events: _events(),
      weekDays: _week,
    ),
  );
  return metrics.dayColumnRects[i].shift(timeline.topLeft);
}

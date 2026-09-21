// The month view's current-week highlight through every view morph: it must
// fade, never blink out, never change colour, and never light the wrong week.
//
// Measured in rendered pixels, since the highlight is painted by different
// widgets on either side of each handoff (month cell, morph cell, week
// column painter) and only the composite tells whether they line up.

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
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

import 'fakes/fake_weather_api_client.dart';

const _green = 0xFF00FF00;
final _boundaryKey = GlobalKey();

Future<void> _pumpCalendar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final now = utcNow();
  await DriftCalendarRepository(db).upsertCalendar(
    Calendar(
      id: legacyCalendarId,
      name: 'Calendar',
      // Pure green, so the calendar's own colour is unmistakable from the
      // theme accent a missing accentColor falls back to.
      colorValue: _green,
      createdAt: now,
      updatedAt: now,
    ),
  );

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
}

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// The cell painting [day]'s fill in whichever layer is showing it.
Rect? _cellRect(WidgetTester tester, DateTime day) {
  final morph = find.byKey(ValueKey(day));
  if (morph.evaluate().isNotEmpty) return tester.getRect(morph.first);
  final cell = find.byWidgetPredicate(
    (w) => w is CalendarDayCell && calendarSameDay(w.date, day),
  );
  if (cell.evaluate().isNotEmpty) return tester.getRect(cell.first);
  return null;
}

/// How strongly green the lower part of [rect] reads: G minus the mean of R
/// and B, maxed over a small strip so one hour line can't hide it.
///
/// [atTop] samples just under the day number instead — for a cell shrinking
/// towards a row *above* today's, whose bottom edge sweeps over today's row.
Future<double> _greenness(
  WidgetTester tester,
  Rect rect, {
  bool atTop = false,
}) async {
  final boundary =
      tester.renderObject(find.byKey(_boundaryKey)) as RenderRepaintBoundary;
  final origin = boundary.localToGlobal(Offset.zero);
  final data = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (bytes!, image.width);
  });
  final (bytes, width) = data!;
  final x = (rect.center.dx - origin.dx).round();
  final top = (rect.top - origin.dy).round();
  final bottom = (rect.bottom - origin.dy).round();
  var best = -255.0;
  for (var dy = 6; dy <= 14; dy++) {
    final y = atTop ? top + 30 + dy : bottom - dy;
    final i = (y * width + x) * 4;
    final r = bytes.getUint8(i), g = bytes.getUint8(i + 1);
    final b = bytes.getUint8(i + 2);
    final v = g - (r + b) / 2;
    if (v > best) best = v;
  }
  return best;
}

/// Taps [label] and samples [day]'s greenness every frame until the morph
/// ends and past the handoff. One reading per frame the cell was on screen,
/// with the cell's height at the time.
Future<List<({double height, double value})>> _sampleSwitch(
  WidgetTester tester,
  String label,
  DateTime day, {
  bool atTop = false,
}) async {
  await tester.tap(find.text(label));
  final readings = <({double height, double value})>[];
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    final rect = _cellRect(tester, day);
    if (rect == null) continue;
    readings.add((
      height: rect.height,
      value: await _greenness(tester, rect, atTop: atTop),
    ));
  }
  await tester.pump(const Duration(seconds: 1));
  return readings;
}

/// Largest frame-to-frame change while the cell is month-sized — year tiles
/// are too small for the probe strip to land on the fill reliably.
double _largestJump(List<({double height, double value})> readings) {
  final big = [
    for (final r in readings)
      if (r.height > 40) r.value,
  ];
  var jump = 0.0;
  for (var i = 1; i < big.length; i++) {
    final d = (big[i] - big[i - 1]).abs();
    if (d > jump) jump = d;
  }
  return jump;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('month → week → month keeps today lit, in the calendar colour', (
    tester,
  ) async {
    await _pumpCalendar(tester);
    final month = await _greenness(tester, _cellRect(tester, _today)!);
    expect(month, greaterThan(40));
    final toWeek = await _sampleSwitch(tester, 'Week', _today);
    final toMonth = await _sampleSwitch(tester, 'Month', _today);
    // Week view's today fill is a little fainter than the month cell's, so
    // the reading may dip — but never towards the bare background, and never
    // in a hue that isn't the calendar's green.
    for (final r in [...toWeek, ...toMonth]) {
      expect(r.value, greaterThan(month * 0.75));
    }
    expect(_largestJump([...toWeek, ...toMonth]), lessThan(15));
  });

  testWidgets('week → month from another week lights today, not that week', (
    tester,
  ) async {
    await _pumpCalendar(tester);
    await _sampleSwitch(tester, 'Week', _today);
    // A neighbouring week that stays inside this month's grid, so it gets a
    // morph row of its own.
    final forward = _today.day <= 14;
    await tester.tap(
      find
          .byIcon(
            forward
                ? PhosphorIconsRegular.caretRight
                : PhosphorIconsRegular.caretLeft,
          )
          .first,
    );
    await tester.pump(const Duration(seconds: 1));
    final otherWeekDay = DateTime(
      _today.year,
      _today.month,
      _today.day + (forward ? 7 : -7),
    );
    final other = await _sampleSwitch(
      tester,
      'Month',
      otherWeekDay,
      atTop: !forward,
    );
    expect(other, isNotEmpty);
    for (final r in other) {
      expect(r.value, lessThan(10));
    }
    expect(
      await _greenness(tester, _cellRect(tester, _today)!),
      greaterThan(40),
    );
  });

  testWidgets('week → month after browsing out of the month morphs that week '
      'into its own month', (tester) async {
    await _pumpCalendar(tester);
    await _sampleSwitch(tester, 'Week', _today);
    // Eight weeks on — always past the grid of the month we came from.
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byIcon(PhosphorIconsRegular.caretRight).first);
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
    final weekStart = calendarWeekStart(_today, true);
    final browsed = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day + 56,
    );

    await tester.tap(find.text('Month'));
    var sawMorphRow = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byKey(ValueKey(browsed)).evaluate().isNotEmpty) {
        sawMorphRow = true;
      }
    }
    await tester.pump(const Duration(seconds: 1));

    expect(sawMorphRow, isTrue);
    final thursday = DateTime(browsed.year, browsed.month, browsed.day + 3);
    expect(find.text(DateFormat.MMMM().format(thursday)), findsOneWidget);
  });

  testWidgets('month ↔ year fades the highlight instead of snapping', (
    tester,
  ) async {
    await _pumpCalendar(tester);
    final toYear = await _sampleSwitch(tester, 'Year', _today);
    final toMonth = await _sampleSwitch(tester, 'Month', _today);
    expect(toYear.first.value, greaterThan(40));
    expect(_largestJump(toYear), lessThan(15));
    expect(_largestJump(toMonth), lessThan(15));
  });
}

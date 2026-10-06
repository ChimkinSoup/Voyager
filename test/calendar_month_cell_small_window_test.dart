// BUG-083: at small window sizes the month cell divided its event area into
// four slots whatever its height, so every bar came out a few pixels tall with
// an illegible title, and the "+N" badge counted only events past the fourth,
// missing those hidden because fewer than four bars fit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

CalendarEvent _event(String id, int hour) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: id,
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: id,
    start: DateTime(2026, 10, 6, hour),
    end: DateTime(2026, 10, 6, hour, 30),
    isFullDay: false,
  );
}

void main() {
  const style = MonthDayCellStyle.full;

  test('every bar a short cell shows is tall enough to read', () {
    for (var cellHeight = 30.0; cellHeight <= 120; cellHeight += 2) {
      final visible = calendarVisibleEventCount(
        cellHeight: cellHeight,
        style: style,
        eventCount: 6,
        hasIndicators: false,
      );
      if (visible == 0) continue;
      final bar = calendarMonthEventBarHeight(
        cellHeight: cellHeight,
        style: style,
        visibleEventCount: visible,
      );
      expect(
        bar,
        greaterThanOrEqualTo(calendarMonthMinReadableBarHeight),
        reason: 'cell $cellHeight shows $visible bars',
      );
    }
  });

  test('a roomy cell keeps its four bars', () {
    expect(
      calendarVisibleEventCount(
        cellHeight: 100,
        style: style,
        eventCount: 6,
        hasIndicators: false,
      ),
      style.maxEventLines,
    );
  });

  testWidgets('"+N" counts every event without a bar', (tester) async {
    final events = [for (var i = 0; i < 6; i++) _event('e$i', 7 + i)];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 120,
            // Room for one readable bar only.
            height: 56,
            child: CalendarDayCell(
              date: DateTime(2026, 10, 6),
              month: DateTime(2026, 10),
              events: events,
              indicators: const [],
              style: style,
            ),
          ),
        ),
      ),
    );

    // One bar drawn, five behind the badge.
    expect(find.text('+5'), findsOneWidget);
  });
}

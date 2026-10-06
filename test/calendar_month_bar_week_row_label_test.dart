// A multi-day event carried over into the next week row of the month view
// showed a blank bar there: only the bar on the event's first day was
// labelled, so the Monday part of a weekend-spanning event couldn't be told
// apart from any other bar in the calendar's colour (BUG-075).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30);
  // Sun Oct 11 20:00 → Mon Oct 12 02:00, as "MD overnight" in the report.
  final event = CalendarEvent(
    id: 'overnight',
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: 'MD overnight',
    start: DateTime(2026, 10, 11, 20),
    end: DateTime(2026, 10, 12, 2),
    isFullDay: false,
  );
  final monday = DateTime(2026, 10, 12);

  Future<void> pumpBar(WidgetTester tester, {required bool isFirstColumn}) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  height: 16,
                  child: CalendarDayEventBar(
                    event: event,
                    date: monday,
                    fontSize: 11,
                    height: 16,
                    isStart: calendarEventBarStartsOnDay(event, monday),
                    isEnd: calendarEventBarEndsOnDay(event, monday),
                    isFirstColumn: isFirstColumn,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('the continuation at the start of a week row is labelled', (
    tester,
  ) async {
    expect(calendarEventBarStartsOnDay(event, monday), isFalse);
    await pumpBar(tester, isFirstColumn: true);
    expect(find.text('MD overnight'), findsOneWidget);
  });

  testWidgets('a continuation inside the same week row stays unlabelled', (
    tester,
  ) async {
    await pumpBar(tester, isFirstColumn: false);
    expect(find.text('MD overnight'), findsNothing);
  });

  // The month↔year zoom draws the month's bars itself while it shrinks them,
  // and labelled only first-day bars, so the label vanished as the zoom began.
  Future<void> pumpMorph(WidgetTester tester, {required bool isFirstColumn}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 100,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MorphDayEventStack(
                        events: [event],
                        date: monday,
                        isFirstColumn: isFirstColumn,
                        // The month end of the zoom: full bars, full text.
                        styleT: 1,
                        maxWidth: 120,
                        cellHeight: 100,
                        dayLayoutSize: 23,
                        morphReverse: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('the zoom labels the continuation at the start of a week row', (
    tester,
  ) async {
    await pumpMorph(tester, isFirstColumn: true);
    expect(find.text('MD overnight'), findsOneWidget);
  });

  testWidgets('the zoom draws that label where the month grid draws it', (
    tester,
  ) async {
    await pumpMorph(tester, isFirstColumn: true);
    final zoomLeft = tester.getTopLeft(find.text('MD overnight')).dx;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 100,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 120,
                    height: 16,
                    child: CalendarDayEventBar(
                      event: event,
                      date: monday,
                      fontSize: 11,
                      height: 16,
                      isStart: false,
                      isEnd: true,
                      isFirstColumn: true,
                      cellMargin: MonthDayCellStyle.full.cellMargin,
                      cellPadding: MonthDayCellStyle.full.cellPadding,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final gridLeft = tester.getTopLeft(find.text('MD overnight')).dx;

    expect(zoomLeft, closeTo(gridLeft, 0.5));
  });

  testWidgets('the zoom leaves a continuation inside the row unlabelled', (
    tester,
  ) async {
    await pumpMorph(tester, isFirstColumn: false);
    expect(find.text('MD overnight'), findsNothing);
  });
}

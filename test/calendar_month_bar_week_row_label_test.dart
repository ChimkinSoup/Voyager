// A multi-day event's month bar carries its title once: on the first bar
// actually drawn. That is the event's first day, unless that day isn't drawn
// — it falls before the grid, or its bar is folded into "+N" — in which case
// the title moves to the first day that does draw it. A bar carried into a
// new week row from a day that drew it stays untitled.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

final _now = DateTime.utc(2026, 9, 30);

CalendarEvent _event(
  String title,
  DateTime start,
  DateTime end, {
  bool isFullDay = false,
}) => CalendarEvent(
  id: title,
  createdAt: _now,
  updatedAt: _now,
  calendarId: 'c1',
  title: title,
  start: start,
  end: end,
  isFullDay: isFullDay,
);

Future<void> _pumpOctober(
  WidgetTester tester,
  List<CalendarEvent> events, {
  double height = 800,
  List<CalendarDayIndicator> indicators = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: height,
            child: MonthDayGrid(
              month: DateTime(2026, 10),
              events: events,
              indicators: indicators,
              // Sunday first: the grid opens on Sun Sep 27.
              weekStartsMonday: false,
              style: MonthDayCellStyle.full,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Expects [title]'s text to start in [day]'s cell: within half a cell of
/// its day number across (the cell's width is the gap to [neighbour], a day
/// beside it), and between its row's day numbers and the next row's
/// ([below] is the day under it).
void _expectTitledIn(
  WidgetTester tester,
  String title, {
  required String day,
  required String neighbour,
  required String below,
}) {
  final number = tester.getCenter(find.text(day).first);
  final width = (tester.getCenter(find.text(neighbour).first).dx - number.dx)
      .abs();
  final nextRow = tester.getCenter(find.text(below).first).dy;
  final at = tester.getTopLeft(find.text(title));
  expect(
    (at.dx - number.dx).abs() < width / 2 &&
        at.dy > number.dy &&
        at.dy < nextRow,
    isTrue,
    reason: '"$title" should be titled in the $day cell',
  );
}

void main() {
  testWidgets('a week-spanning event is titled on its first day only', (
    tester,
  ) async {
    // Sat Oct 10 → Sun Oct 18: three week rows, as "Reading Week".
    final event = _event(
      'Reading Week',
      DateTime(2026, 10, 10),
      DateTime(2026, 10, 18),
      isFullDay: true,
    );
    await _pumpOctober(tester, [event]);

    expect(find.text('Reading Week'), findsOneWidget);
    _expectTitledIn(
      tester,
      'Reading Week',
      day: '10',
      neighbour: '9',
      below: '17',
    );
  });

  testWidgets('an event begun before the grid is titled on its first cell', (
    tester,
  ) async {
    final event = _event(
      'Carried in',
      DateTime(2026, 9, 20),
      DateTime(2026, 10, 3),
      isFullDay: true,
    );
    await _pumpOctober(tester, [event]);

    expect(find.text('Carried in'), findsOneWidget);
    // Sun Sep 27 opens the grid; Oct 27 comes later in the tree.
    _expectTitledIn(
      tester,
      'Carried in',
      day: '27',
      neighbour: '28',
      below: '4',
    );
  });

  testWidgets('an event folded into "+N" on its first day is titled on the '
      'next day, where it is first drawn', (tester) async {
    // Wed Oct 7 23:00 → Fri Oct 9 10:00, under three earlier events on Oct 7.
    // At this height a cell fits four bars, but Oct 7's indicator dot leaves
    // room for three: the event is folded into "+1" there and drawn on Oct 8.
    final event = _event(
      'Folded',
      DateTime(2026, 10, 7, 23),
      DateTime(2026, 10, 9, 10),
    );
    await _pumpOctober(
      tester,
      [
        for (var i = 0; i < 3; i++)
          _event(
            'Filler $i',
            DateTime(2026, 10, 7, 8 + i),
            DateTime(2026, 10, 7, 8 + i, 30),
          ),
        event,
      ],
      height: 552,
      indicators: [
        CalendarDayIndicator(
          day: DateTime(2026, 10, 7),
          colorValue: 0xFF4CAF50,
          label: 'dot',
        ),
      ],
    );

    expect(find.text('Folded'), findsOneWidget);
    _expectTitledIn(tester, 'Folded', day: '8', neighbour: '9', below: '15');
  });

  testWidgets('the zoom sizes the "+N" cut-off from the month cell it hands '
      'over to', (tester) async {
    await _pumpOctober(tester, const [], height: 552);

    final cell = find.byType(CalendarDayCell).first;
    final content = find
        .descendant(of: cell, matching: find.byType(LayoutBuilder))
        .first;
    expect(
      calendarMonthCellLayoutHeight(tester.getSize(cell).height),
      tester.getSize(content).height,
    );
  });

  // The month↔year zoom draws the month's bars itself while it shrinks them,
  // and titles them as the grid does.
  final overnight = _event(
    'MD overnight',
    DateTime(2026, 10, 11, 20),
    DateTime(2026, 10, 12, 2),
  );
  final monday = DateTime(2026, 10, 12);

  Future<void> pumpMorph(
    WidgetTester tester, {
    required List<CalendarEvent?>? previousDayShown,
  }) => tester.pumpWidget(
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
                    events: [overnight],
                    date: monday,
                    isFirstColumn: true,
                    previousDayShown: previousDayShown,
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

  testWidgets('the zoom leaves a bar carried from a drawn day untitled', (
    tester,
  ) async {
    await pumpMorph(tester, previousDayShown: [overnight]);
    expect(find.text('MD overnight'), findsNothing);
  });

  testWidgets('the zoom titles a bar whose day before is outside the grid', (
    tester,
  ) async {
    await pumpMorph(tester, previousDayShown: null);
    expect(find.text('MD overnight'), findsOneWidget);
  });

  testWidgets('the zoom draws that title where the month grid draws it', (
    tester,
  ) async {
    await pumpMorph(tester, previousDayShown: null);
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
                      event: overnight,
                      date: monday,
                      fontSize: 11,
                      height: 16,
                      isStart: false,
                      isEnd: true,
                      isFirstColumn: true,
                      showTitle: true,
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
}

// MonthDayGrid keeps the weeks it packed from an events list, so a rebuild
// for anything else — to-do markers moving — skips the packing. These pin
// that the kept packing is only reused for the same list, month and layout.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

CalendarEvent _event(String title, DateTime day) {
  final stamp = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: title,
    createdAt: stamp,
    updatedAt: stamp,
    calendarId: 'c1',
    title: title,
    start: DateTime(day.year, day.month, day.day, 9),
    end: DateTime(day.year, day.month, day.day, 10),
    isFullDay: false,
  );
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  required DateTime month,
  required List<CalendarEvent> events,
  List<CalendarTodoMarker> todoMarkers = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 800,
            child: MonthDayGrid(
              month: month,
              events: events,
              indicators: const [],
              todoMarkers: todoMarkers,
              weekStartsMonday: true,
              style: MonthDayCellStyle.full,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a new events list is packed again', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final month = DateTime(2026, 9, 1);
    final first = [_event('Standup', DateTime(2026, 9, 9))];

    await _pumpGrid(tester, month: month, events: first);
    expect(find.text('Standup'), findsOneWidget);

    await _pumpGrid(
      tester,
      month: month,
      events: [...first, _event('Dentist', DateTime(2026, 9, 10))],
    );
    expect(find.text('Standup'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
  });

  testWidgets('the same list is packed again for another month', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final events = [
      _event('September', DateTime(2026, 9, 9)),
      _event('October', DateTime(2026, 10, 14)),
    ];

    await _pumpGrid(tester, month: DateTime(2026, 9, 1), events: events);
    expect(find.text('September'), findsOneWidget);
    expect(find.text('October'), findsNothing);

    await _pumpGrid(tester, month: DateTime(2026, 10, 1), events: events);
    expect(find.text('October'), findsOneWidget);
    expect(find.text('September'), findsNothing);
  });

  testWidgets('a rebuild for markers alone keeps the events', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final month = DateTime(2026, 9, 1);
    final events = [_event('Standup', DateTime(2026, 9, 9))];

    await _pumpGrid(tester, month: month, events: events);
    final due = DateTime(2026, 9, 10);
    await _pumpGrid(
      tester,
      month: month,
      events: events,
      todoMarkers: [
        CalendarTodoMarker(
          taskId: 't1',
          listId: 'l1',
          colorValue: 0xFF7C9EFF,
          dueDate: due,
          sortKey: due,
          title: 'File taxes',
        ),
      ],
    );

    expect(find.text('Standup'), findsOneWidget);
    expect(find.byType(CalendarDayTodoIcons), findsOneWidget);
  });
}

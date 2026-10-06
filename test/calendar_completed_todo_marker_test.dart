// BUG-080: completing a to-do from the calendar removed its marker: completed
// tasks were dropped when the markers were built, so the bars' completed style
// (WEEKLY_CALENDAR.md §IV) never showed and the task couldn't be unticked from
// the calendar. They now stay, unless "Hide completed tasks" is on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30);
  final due = DateTime(2026, 10, 1, 10, 15);
  TodoTask task(String id, {bool completed = false}) => TodoTask(
    id: id,
    createdAt: now,
    updatedAt: now,
    listId: 'cal-tasks',
    title: id,
    dueDate: due,
    completed: completed,
  );

  test('a completed task keeps its marker, in its completed style', () {
    final markers = buildCalendarTodoMarkers(
      [task('open'), task('done', completed: true)],
      const {},
      fallbackColorValue: 0xFF7C9EFF,
    );

    final onDay = calendarTodoMarkersForDay(markers, DateTime(2026, 10, 1));
    expect(onDay.map((m) => (m.taskId, m.completed)), [
      ('open', false),
      ('done', true),
    ]);
  });

  test('"Hide completed tasks" still hides it', () {
    final markers = buildCalendarTodoMarkers(
      [task('open'), task('done', completed: true)],
      const {},
      fallbackColorValue: 0xFF7C9EFF,
      hideCompleted: true,
    );

    expect(markers.map((m) => m.taskId), ['open']);
  });

  // The month cell shows at most a few icons. Completed tasks count toward
  // them now, so they must not push an open task out of view.
  testWidgets('an open task keeps its icon slot ahead of completed ones', (
    tester,
  ) async {
    final markers = calendarTodoMarkersForDay(
      buildCalendarTodoMarkers(
        [
          for (var i = 0; i < calendarMaxTodoIconsPerDay; i++)
            task(
              'done $i',
              completed: true,
            ).copyWith(dueDate: DateTime(2026, 10, 1, 8, i)),
          task('open').copyWith(dueDate: DateTime(2026, 10, 1, 17)),
        ],
        const {},
        fallbackColorValue: 0xFF7C9EFF,
      ),
      DateTime(2026, 10, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Center(child: CalendarDayTodoIcons(markers: markers)),
      ),
    );

    final alphas = tester
        .widgetList<Icon>(find.byType(Icon))
        .map((icon) => icon.color!.a)
        .toList();
    expect(alphas, hasLength(calendarMaxTodoIconsPerDay));
    expect(alphas.where((a) => a == 1.0), hasLength(1));
  });
}

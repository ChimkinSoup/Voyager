// The day cell's todo popover follows the live task list.
//
// showContextualPopover pushes a route, so a popover built from a list handed
// in at open time holds that list for as long as it is up. Deleting a task from
// the popover's own right-click menu left the deleted row sitting in the menu
// until it was closed and reopened.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

final _day = DateTime(2026, 3, 14);

/// The list the overridden [calendarTodoMarkersProvider] serves, so a test can
/// move it the way a delete moves the real one.
final _liveMarkers = StateProvider<List<CalendarTodoMarker>>((ref) => const []);

CalendarTodoMarker _marker(String id, String title) => CalendarTodoMarker(
  taskId: id,
  listId: 'list',
  colorValue: 0xFF3366FF,
  dueDate: _day.add(const Duration(hours: 9)),
  sortKey: _day,
  title: title,
);

Future<ProviderContainer> _pumpPopover(
  WidgetTester tester,
  List<CalendarTodoMarker> markers,
) async {
  final container = ProviderContainer(
    overrides: [
      _liveMarkers.overrideWith((ref) => markers),
      calendarTodoMarkersProvider.overrideWith(
        (ref) async => ref.watch(_liveMarkers),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CalendarDayTodoPopover(
                  day: _day,
                  todos: markers,
                  onTodoTap: (_) {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a task deleted while the popover is open leaves it', (
    tester,
  ) async {
    final markers = [_marker('a', 'Task A'), _marker('b', 'Task B')];
    final container = await _pumpPopover(tester, markers);

    expect(find.text('Task A'), findsOneWidget);
    expect(find.text('Task B'), findsOneWidget);

    // What a delete does to the provider the popover reads from.
    container.read(_liveMarkers.notifier).state = [markers.last];
    await tester.pumpAndSettle();

    expect(find.text('Task A'), findsNothing);
    expect(find.text('Task B'), findsOneWidget);
  });

  testWidgets('the popover closes once the day has no tasks left', (
    tester,
  ) async {
    final container = await _pumpPopover(tester, [_marker('a', 'Task A')]);
    expect(find.text('Task A'), findsOneWidget);

    container.read(_liveMarkers.notifier).state = const [];
    await tester.pumpAndSettle();

    expect(
      find.byType(CalendarDayTodoPopover),
      findsNothing,
      reason: 'an empty card over the grid says less than no card at all',
    );
  });
}

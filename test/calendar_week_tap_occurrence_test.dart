// BUG-078: a click on a repeating event in the Week view reported only the
// event, so the page opened the occurrence on its focused date (the week's
// anchor) whatever column was clicked, and "This event only" edited that day.
// The tap now carries the clicked column's day.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_week_timeline.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30);
  final walk = CalendarEvent(
    id: 'walk',
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: 'Daily walk',
    start: DateTime(2026, 10, 1, 7),
    end: DateTime(2026, 10, 1, 7, 30),
    isFullDay: false,
    recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
  );
  final allDay = CalendarEvent(
    id: 'rest',
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: 'Rest day',
    start: DateTime(2026, 10, 1),
    end: DateTime(2026, 10, 1, 23, 59),
    isFullDay: true,
    recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
  );

  Future<List<(String, DateTime)>> tapNth(
    WidgetTester tester,
    String title,
    int index,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final taps = <(String, DateTime)>[];
    final controller = ScrollController(initialScrollOffset: 6 * 50);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CalendarWeekTimeline(
              // Week of Mon Oct 12, 2026.
              weekStart: DateTime(2026, 10, 12),
              events: [walk, allDay],
              todoMarkers: const [],
              weekStartsMonday: true,
              scrollController: controller,
              entryFadeEnabled: false,
              onEventTap: (event, day) => taps.add((event.id, day)),
              onTodoTap: (_) {},
              onSlotTap: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bars = find.text(title);
    expect(bars, findsNWidgets(7));
    await tester.tap(bars.at(index));
    await tester.pumpAndSettle();
    return taps;
  }

  testWidgets('clicking Friday\'s timed occurrence reports Friday', (
    tester,
  ) async {
    final taps = await tapNth(tester, 'Daily walk', 4);
    expect(taps, [('walk', DateTime(2026, 10, 16))]);
  });

  testWidgets('clicking Wednesday\'s all-day occurrence reports Wednesday', (
    tester,
  ) async {
    final taps = await tapNth(tester, 'Rest day', 2);
    expect(taps, [('rest', DateTime(2026, 10, 14))]);
  });
}

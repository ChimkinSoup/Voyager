// A done event is drawn as an outline instead of a fill. The outline must not
// push its title in: the month↔week morph lays titles out without it, so an
// inset title jumped 1.5px at each end of the morph, and in week view it sat
// low in its pill.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

CalendarEvent _event(String id, {required bool done}) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: id,
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: id,
    start: DateTime(2026, 3, 2, 9),
    end: DateTime(2026, 3, 2, 10),
    isFullDay: false,
    isDone: done,
  );
}

Future<Offset> _titleOffset(
  WidgetTester tester,
  Widget Function(CalendarEvent) build,
  CalendarEvent event,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 120, height: 22, child: build(event)),
        ),
      ),
    ),
  );
  return tester.getTopLeft(find.text(event.title));
}

void main() {
  final day = DateTime(2026, 3, 2);

  testWidgets('week block: a done title sits where an undone one does', (
    tester,
  ) async {
    Widget block(CalendarEvent e) =>
        CalendarWeekEventBlock(event: e, day: day, onTap: () {});
    expect(
      await _titleOffset(tester, block, _event('done', done: true)),
      await _titleOffset(tester, block, _event('open', done: false)),
    );
  });

  Future<void> pumpList(WidgetTester tester, Widget child) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SizedBox(width: 300, height: 600, child: child)),
        ),
      );

  // Where a title sits inside its tile, and the tile's size.
  (Offset, Size) inTile(WidgetTester tester, String title) {
    final tile = find
        .ancestor(of: find.text(title), matching: find.byType(DecoratedBox))
        .first;
    return (
      tester.getTopLeft(find.text(title)) - tester.getTopLeft(tile),
      tester.getSize(tile),
    );
  }

  testWidgets('"+N" popover: a done title sits where an undone one does', (
    tester,
  ) async {
    await pumpList(
      tester,
      CalendarDayOverflowEventsPopover(
        day: day,
        events: [_event('done', done: true), _event('open', done: false)],
        onEventTap: (_) {},
      ),
    );
    expect(inTile(tester, 'done'), inTile(tester, 'open'));
  });

  testWidgets('day view: a done tile lays out like an undone one', (
    tester,
  ) async {
    await pumpList(
      tester,
      DayHourGrid(
        day: day,
        events: [_event('done', done: true), _event('open', done: false)],
        onHourTap: (_) {},
      ),
    );
    expect(inTile(tester, 'done'), inTile(tester, 'open'));
  });

  testWidgets('month bar: a done title sits where an undone one does', (
    tester,
  ) async {
    Widget bar(CalendarEvent e) =>
        CalendarDayEventBar(event: e, date: day, fontSize: 9, height: 22);
    expect(
      await _titleOffset(tester, bar, _event('done', done: true)),
      await _titleOffset(tester, bar, _event('open', done: false)),
    );
  });
}

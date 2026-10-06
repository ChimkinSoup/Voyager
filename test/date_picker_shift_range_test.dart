// The event panel's date picker used to read a second tap as the end of a
// range, so re-pointing a one-day event from Oct 3 to Oct 4 turned it into
// Oct 3 → Oct 4. A plain tap now picks a single day; Shift+tap, or a long
// press on touch, starts a new range at the tapped day, ignoring the current
// dates, and the next tap ends it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

enum _Press { tap, shiftTap, hold }

void main() {
  /// Opens a picker on a one-day Oct 3 event and returns what it pops with.
  /// [presses] are day numbers in October 2026, each with how it's pressed.
  /// [dates], when given, supplies the picker's initial dates, so a test can
  /// change them while the picker is open.
  Future<DateTimeRange?> pick(
    WidgetTester tester,
    List<(int day, _Press press)> presses, {
    ValueNotifier<DateTime>? dates,
    void Function()? betweenPresses,
  }) async {
    final initial = dates ?? ValueNotifier(DateTime(2026, 10, 3, 9));
    DateTimeRange? result;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<DateTimeRange>(
                context: context,
                builder: (_) => Dialog(
                  child: SizedBox(
                    width: 320,
                    height: 380,
                    child: ValueListenableBuilder<DateTime>(
                      valueListenable: initial,
                      builder: (_, start, _) => DateSelectorPopover(
                        initialStartDate: start,
                        initialEndDate: start.add(const Duration(hours: 1)),
                      ),
                    ),
                  ),
                ),
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (final (i, (day, press)) in presses.indexed) {
      if (i > 0) betweenPresses?.call();
      await tester.pumpAndSettle();
      expect(closed, isFalse, reason: 'picker closed before press on $day');
      // October 2026 opens on Sep 27, so the first match is in October.
      final cell = find.text('$day').first;
      switch (press) {
        case _Press.tap:
          await tester.tap(cell);
        case _Press.shiftTap:
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.tap(cell);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        case _Press.hold:
          await tester.longPress(cell);
      }
      await tester.pumpAndSettle();
    }
    expect(closed, isTrue);
    return result;
  }

  testWidgets('a plain tap moves the event to that single day', (tester) async {
    final range = await pick(tester, [(5, _Press.tap)]);
    expect(range!.start, DateTime(2026, 10, 5));
    expect(range.end, DateTime(2026, 10, 5));
  });

  testWidgets('Shift+tap then a plain tap makes a new range', (tester) async {
    final range = await pick(tester, [(10, _Press.shiftTap), (12, _Press.tap)]);
    expect(range!.start, DateTime(2026, 10, 10));
    expect(range.end, DateTime(2026, 10, 12));
  });

  testWidgets('the second tap may come before the first', (tester) async {
    final range = await pick(tester, [
      (12, _Press.shiftTap),
      (8, _Press.shiftTap),
    ]);
    expect(range!.start, DateTime(2026, 10, 8));
    expect(range.end, DateTime(2026, 10, 12));
  });

  testWidgets('on touch, a long press then a tap makes a range', (
    tester,
  ) async {
    final range = await pick(tester, [(10, _Press.hold), (12, _Press.tap)]);
    expect(range!.start, DateTime(2026, 10, 10));
    expect(range.end, DateTime(2026, 10, 12));
  });

  testWidgets('new initial dates cancel a range waiting for its end', (
    tester,
  ) async {
    final dates = ValueNotifier(DateTime(2026, 10, 3, 9));
    final range = await pick(
      tester,
      [(10, _Press.shiftTap), (5, _Press.tap)],
      dates: dates,
      betweenPresses: () => dates.value = DateTime(2026, 10, 20, 9),
    );
    expect(range!.start, DateTime(2026, 10, 5));
    expect(range.end, DateTime(2026, 10, 5));
  });

  testWidgets('inline mode reports the pressed day, Shift or not', (
    tester,
  ) async {
    final picked = <DateTime>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 380,
            child: DateSelectorPopover(
              initialStartDate: DateTime(2026, 10, 3),
              initialEndDate: DateTime(2026, 10, 3),
              inlineMode: true,
              onDateSelected: picked.add,
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('10').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.longPress(find.text('12').first);
    await tester.pump();
    expect(picked, [DateTime(2026, 10, 10), DateTime(2026, 10, 12)]);
  });
}

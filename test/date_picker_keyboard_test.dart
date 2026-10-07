// BUG-111: the date picker opened from the keyboard, but Left/Right only
// turned the month and Up/Down did nothing, so Enter always picked the day it
// opened on. The arrows now move the highlighted day — across month ends —
// and Enter or Ctrl+Enter picks it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

void main() {
  /// Opens a single-date picker on Oct 3 2026, sends [keys], and returns
  /// what it popped with (null while it is still open).
  Future<DateTimeRange?> pick(
    WidgetTester tester,
    List<LogicalKeyboardKey> keys, {
    bool ctrlEnter = false,
  }) async {
    DateTimeRange? result;
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
                    child: DateSelectorPopover(
                      initialStartDate: DateTime(2026, 10, 3),
                      initialEndDate: DateTime(2026, 10, 3),
                      singleDateMode: true,
                    ),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (final key in keys) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    if (ctrlEnter) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    } else {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    }
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Left then Enter picks the day before', (tester) async {
    final range = await pick(tester, [LogicalKeyboardKey.arrowLeft]);
    expect(range!.start, DateTime(2026, 10, 2));
    expect(range.end, DateTime(2026, 10, 2));
  });

  testWidgets('Right and Down move by a day and a week', (tester) async {
    final range = await pick(tester, [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    ]);
    expect(range!.start, DateTime(2026, 10, 11));
  });

  testWidgets('Up crosses into the previous month', (tester) async {
    final range = await pick(tester, [LogicalKeyboardKey.arrowUp]);
    expect(range!.start, DateTime(2026, 9, 26));
    expect(find.text('September 2026'), findsNothing, reason: 'closed');
  });

  testWidgets('Ctrl+Enter picks the highlighted day too', (tester) async {
    final range = await pick(tester, [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowLeft,
    ], ctrlEnter: true);
    expect(range!.start, DateTime(2026, 10, 1));
  });
}

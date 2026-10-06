// Typing an end time keystroke by keystroke used to move the start for good:
// on the way to "12:30p" the prefix "12" parses as 12:00 AM, before the start,
// and the failsafe pushed the start back to 11 PM the day before. The rest of
// the typing only moved the end, so "11 AM → 12:30p" saved as 11 PM the
// previous day → 12:30 PM (BUG-074). An end at or before the start now waits
// until the user is done with the field, and the failsafe applies to that.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';

void main() {
  Future<ValueGetter<DateTimeRange?>> pumpPopover(
    WidgetTester tester,
    DateTime start,
  ) async {
    DateTimeRange? latest;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TimeRangePopover(
              initialStart: start,
              initialEnd: start.add(const Duration(hours: 1)),
              onChanged: (range) => latest = range,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return () => latest;
  }

  Finder startField() => find.byType(EditableText).first;
  Finder endField() => find.byType(EditableText).last;

  Future<void> typeInto(
    WidgetTester tester,
    Finder field,
    String text, {
    void Function()? afterEach,
  }) async {
    for (var i = 1; i <= text.length; i++) {
      await tester.enterText(field, text.substring(0, i));
      await tester.pump();
      afterEach?.call();
    }
  }

  testWidgets('a prefix of the end that parses before the start never moves '
      'the start', (tester) async {
    final latest = await pumpPopover(tester, DateTime(2026, 9, 30));

    await tester.enterText(startField(), '11a');
    await tester.pump();
    expect(latest()!.start, DateTime(2026, 9, 30, 11));

    await tester.tap(endField());
    await tester.pump();
    await typeInto(
      tester,
      endField(),
      '12:30p',
      afterEach: () => expect(latest()!.start, DateTime(2026, 9, 30, 11)),
    );

    expect(latest()!.start, DateTime(2026, 9, 30, 11));
    expect(latest()!.end, DateTime(2026, 9, 30, 12, 30));
  });

  testWidgets('a finished end before the start pushes the start back once the '
      'field is left, and a duration chip then keeps that start', (
    tester,
  ) async {
    final latest = await pumpPopover(tester, DateTime(2026, 10, 1, 14));

    await tester.tap(endField());
    await tester.pump();
    await typeInto(tester, endField(), '1:30p');
    // Still being typed: nothing applied yet.
    expect(latest(), isNull);

    await tester.tap(startField());
    await tester.pump();
    expect(latest()!.end, DateTime(2026, 10, 1, 13, 30));
    expect(latest()!.start, DateTime(2026, 10, 1, 12, 30));

    await tester.tap(find.text('30 m'));
    await tester.pump();
    expect(latest()!.start, DateTime(2026, 10, 1, 12, 30));
    expect(latest()!.end, DateTime(2026, 10, 1, 13));
  });
}

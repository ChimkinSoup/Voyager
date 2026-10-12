// Turning the month scrolls the date picker's grid as one strip of weeks:
// the next month's greyed days at the bottom slide up into place and
// brighten, rather than the grid flipping to the new month at once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

import 'date_picker_settings_scope.dart';

Future<void> _pumpPicker(WidgetTester tester, DateTime date) async {
  await tester.pumpWidget(
    datePickerSettingsScope(
      weekStartsOnMonday: true,
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 400,
              child: DateSelectorPopover(
                initialStartDate: date,
                initialEndDate: date,
                singleDateMode: true,
                inlineMode: true,
                onDateSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// [date]'s number in the grid: the week rows are keyed by their start.
Finder _day(DateTime date) => find.descendant(
  of: find.byKey(ValueKey(calendarWeekStart(date, true))),
  matching: find.text('${date.day}'),
);

void main() {
  double y(WidgetTester tester, DateTime date) =>
      tester.getCenter(_day(date)).dy;
  double ink(WidgetTester tester, DateTime date) => tester
      .widget<FadeTransition>(
        find
            .ancestor(of: _day(date), matching: find.byType(FadeTransition))
            .first,
      )
      .opacity
      .value;

  testWidgets('next month scrolls the weeks up and brightens its days', (
    tester,
  ) async {
    // Monday start: January 2026's grid opens on Dec 29 and ends on Feb 8;
    // February's opens on Jan 26, four rows further down.
    await _pumpPicker(tester, DateTime(2026, 1, 15));
    final feb5 = DateTime(2026, 2, 5);
    final rowHeight =
        y(tester, DateTime(2026, 1, 12)) - y(tester, DateTime(2026, 1, 5));

    final startY = y(tester, feb5);
    expect(ink(tester, feb5), closeTo(0.3, 0.01));

    await tester.tap(find.byIcon(PhosphorIconsRegular.caretRight));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final midY = y(tester, feb5);
    expect(midY, lessThan(startY - 0.5 * rowHeight), reason: 'scrolling up');
    expect(midY, greaterThan(startY - 4 * rowHeight + 1), reason: 'not there');
    expect(ink(tester, feb5), inExclusiveRange(0.3, 1.0));

    // A frame of the scroll moves the rows and repaints the fade; it
    // doesn't build the day cells again.
    final text = tester.widget<Text>(_day(feb5));
    await tester.pump(const Duration(milliseconds: 40));
    expect(y(tester, feb5), lessThan(midY), reason: 'still moving');
    expect(tester.widget<Text>(_day(feb5)), same(text));

    await tester.pumpAndSettle();
    expect(y(tester, feb5), closeTo(startY - 4 * rowHeight, 0.5));
    expect(ink(tester, feb5), closeTo(1.0, 0.01));
    expect(
      _day(DateTime(2026, 1, 5)),
      findsNothing,
      reason: 'weeks scrolled out of view are dropped once it settles',
    );
  });

  testWidgets('a second turn mid-scroll runs on instead of snapping', (
    tester,
  ) async {
    // May 2026 → April is four rows, April → March five more: the second
    // turn lands well past a grid's height of rows still to go.
    await _pumpPicker(tester, DateTime(2026, 5, 15));
    final caretLeft = find.byIcon(PhosphorIconsRegular.caretLeft);

    await tester.tap(caretLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final apr20 = DateTime(2026, 4, 20);
    final aprInk = ink(tester, apr20);
    expect(aprInk, inExclusiveRange(0.3, 1.0));

    await tester.tap(caretLeft);
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue, reason: 'no snap');
    expect(
      ink(tester, apr20),
      closeTo(aprInk, 0.05),
      reason: "April's half-faded days fade on from where they were",
    );

    await tester.pumpAndSettle();
    expect(find.text('March 2026'), findsOneWidget);
    expect(ink(tester, DateTime(2026, 3, 20)), closeTo(1.0, 0.01));
    expect(ink(tester, DateTime(2026, 4, 5)), closeTo(0.3, 0.01));
  });

  testWidgets('quick turns build at most a grid of rows ahead', (tester) async {
    await _pumpPicker(tester, DateTime(2026, 1, 15));
    final caretRight = find.byIcon(PhosphorIconsRegular.caretRight);
    final weekRows = find.byWidgetPredicate((w) => w.key is ValueKey<DateTime>);

    // Eight turns well inside one scroll's 250ms would pile up some 35 rows.
    for (var i = 0; i < 8; i++) {
      await tester.tap(caretRight);
      await tester.pump(const Duration(milliseconds: 10));
      expect(weekRows.evaluate().length, lessThanOrEqualTo(13));
    }

    await tester.pumpAndSettle();
    expect(find.text('September 2026'), findsOneWidget);
    expect(ink(tester, DateTime(2026, 9, 15)), closeTo(1.0, 0.01));
    expect(weekRows, findsNWidgets(6));
  });
}

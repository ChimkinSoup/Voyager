// The repeat picker: five presets on the first page, a custom editor behind
// "Custom…" for "every X units" and specific weekdays.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/repeat_selector_popover.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';

final _anchor = DateTime(2026, 3, 2); // a Monday

/// Hosts the popover directly, for tests that only read what it renders.
Future<void> _pump(
  WidgetTester tester, {
  RecurrenceRule initial = RecurrenceRule.none,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: kRepeatPopoverWidth,
            child: RepeatSelectorPopover(
              initialRule: initial,
              anchor: _anchor,
              accentColor: const Color(0xFF3366FF),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Reads what the popover popped with, by driving a real route.
Future<RecurrenceRule?> _choose(
  WidgetTester tester,
  Future<void> Function(WidgetTester) interact, {
  RecurrenceRule initial = RecurrenceRule.none,
}) async {
  RecurrenceRule? captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await Navigator.of(context).push<RecurrenceRule>(
                  MaterialPageRoute(
                    builder: (_) => Center(
                      child: SizedBox(
                        width: kRepeatPopoverWidth,
                        child: Material(
                          child: RepeatSelectorPopover(
                            initialRule: initial,
                            anchor: _anchor,
                            accentColor: const Color(0xFF3366FF),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await interact(tester);
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('lists the five presets plus a custom entry', (tester) async {
    await _pump(tester);
    expect(find.text('Does not repeat'), findsOneWidget);
    expect(find.text('Every day'), findsOneWidget);
    // A plain weekly rule names the weekday the anchor falls on.
    expect(find.text('Every week on Mon'), findsOneWidget);
    expect(find.text('Every month'), findsOneWidget);
    expect(find.text('Every year'), findsOneWidget);
    expect(find.text('Custom…'), findsOneWidget);
  });

  testWidgets('picking a preset returns that rule', (tester) async {
    final rule = await _choose(tester, (t) async {
      await t.tap(find.text('Every month'));
    });
    expect(rule, const RecurrenceRule(frequency: EventRecurrence.monthly));
  });

  testWidgets('picking "Does not repeat" returns none', (tester) async {
    final rule = await _choose(
      tester,
      (t) async => t.tap(find.text('Does not repeat')),
      initial: const RecurrenceRule(frequency: EventRecurrence.weekly),
    );
    expect(rule, RecurrenceRule.none);
    expect(rule!.repeats, isFalse);
  });

  testWidgets('custom builds an every-3-days rule', (tester) async {
    final rule = await _choose(tester, (t) async {
      await t.tap(find.text('Custom…'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '3');
      await t.pumpAndSettle();
      // The unit dropdown defaults to days, and the summary line confirms it
      // before the user commits.
      expect(find.text('Every 3 days'), findsOneWidget);
      await t.tap(find.text('Done'));
    });
    expect(
      rule,
      const RecurrenceRule(frequency: EventRecurrence.daily, interval: 3),
    );
  });

  testWidgets('custom builds a weekly rule on chosen weekdays', (tester) async {
    final rule = await _choose(tester, (t) async {
      await t.tap(find.text('Custom…'));
      await t.pumpAndSettle();
      await t.tap(find.byType(DropdownButton<EventRecurrence>));
      await t.pumpAndSettle();
      await t.tap(find.text('week').last);
      await t.pumpAndSettle();
      // Monday is preselected from the anchor; add Wednesday and Friday.
      await t.tap(find.widgetWithText(SizedBox, 'W').first);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(SizedBox, 'F').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Done'));
    });
    expect(rule!.frequency, EventRecurrence.weekly);
    expect(rule.interval, 1);
    expect(rule.weekdays, {
      DateTime.monday,
      DateTime.wednesday,
      DateTime.friday,
    });
  });

  testWidgets('cancel on the custom page returns to the preset list', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Custom…'));
    await tester.pumpAndSettle();
    expect(find.text('Custom repeat'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Custom repeat'), findsNothing);
    expect(find.text('Every month'), findsOneWidget);
  });

  testWidgets('an existing custom rule opens showing its own description', (
    tester,
  ) async {
    await _pump(
      tester,
      initial: const RecurrenceRule(
        frequency: EventRecurrence.weekly,
        interval: 2,
        weekdays: {DateTime.tuesday, DateTime.thursday},
      ),
    );
    // Opens straight onto the custom page, seeded with the stored rule.
    expect(find.text('Custom repeat'), findsOneWidget);
    expect(find.text('Every 2 weeks on Tue, Thu'), findsOneWidget);
  });

  testWidgets('the last weekday cannot be cleared', (tester) async {
    await _pump(
      tester,
      initial: const RecurrenceRule(
        frequency: EventRecurrence.weekly,
        interval: 2,
        weekdays: {DateTime.tuesday},
      ),
    );
    expect(find.text('Every 2 weeks on Tue'), findsOneWidget);
    // Clearing the only selected day would silently fall back to the anchor's
    // weekday, so the toggle is refused instead.
    await tester.tap(find.widgetWithText(SizedBox, 'T').first);
    await tester.pumpAndSettle();
    expect(find.text('Every 2 weeks on Tue'), findsOneWidget);
  });
}

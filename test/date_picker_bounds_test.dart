// A day picker's first and last days: days and quick picks outside them
// are greyed out and can't be picked, by click or by keyboard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

import 'date_picker_settings_scope.dart';

Future<List<DateTime>> _pump(
  WidgetTester tester, {
  required DateTime initial,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  final picks = <DateTime>[];
  await tester.pumpWidget(
    datePickerSettingsScope(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: SizedBox.fromSize(
            size: kDateSelectorPopoverSize,
            child: DateSelectorPopover(
              initialStartDate: initial,
              initialEndDate: initial,
              singleDateMode: true,
              inlineMode: true,
              firstDate: firstDate,
              lastDate: lastDate,
              onDateSelected: picks.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picks;
}

void main() {
  testWidgets('nothing after the last day can be picked', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picks = await _pump(tester, initial: today, lastDate: today);

    await tester.tap(find.text('Tomorrow'));
    await tester.tap(find.text('Next Week'));
    await tester.pump();
    expect(picks, isEmpty);

    // The highlight stops at the last day.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picks, [today]);

    await tester.tap(find.text('Today'));
    await tester.pump();
    expect(picks, [today, today]);
  });

  testWidgets('nothing before the first day can be picked', (tester) async {
    final picks = await _pump(
      tester,
      initial: DateTime(2026, 10, 15),
      firstDate: DateTime(2026, 10, 15),
    );
    await tester.tap(find.text('14'));
    await tester.pump();
    expect(picks, isEmpty);
    await tester.tap(find.text('16'));
    await tester.pump();
    expect(picks, [DateTime(2026, 10, 16)]);
  });
}

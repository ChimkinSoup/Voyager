// The date picker follows the "Monday start" setting: the grid opens on a
// Monday instead of a Sunday, and the weekday labels move with it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

import 'date_picker_settings_scope.dart';

void main() {
  for (final monday in [false, true]) {
    testWidgets('week starts on ${monday ? 'Monday' : 'Sunday'}', (
      tester,
    ) async {
      // October 2026 opens on a Thursday.
      final date = DateTime(2026, 10, 14);
      await tester.pumpWidget(
        datePickerSettingsScope(
          weekStartsOnMonday: monday,
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

      final days = find.descendant(
        of: find.byType(ClipRect),
        matching: find.byType(Text),
      );
      expect(
        tester.widget<Text>(days.first).data,
        monday ? '28' : '27',
        reason:
            'the grid opens on the last ${monday ? 'Monday' : 'Sunday'} '
            'of September',
      );

      // Each label heads its own weekday's column: Oct 7 is a Wednesday.
      expect(
        tester.getCenter(find.text('W')).dx,
        closeTo(tester.getCenter(find.text('7').first).dx, 0.5),
      );
    });
  }
}

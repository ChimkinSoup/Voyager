import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

void main() {
  group('Calendar event layout and styling', () {
    test('calendarEventCornerRadius is 3.0', () {
      expect(calendarEventCornerRadius, equals(3.0));
    });

    test('calendarMonthEventBarHeight expands for 4 events to reach bottom padding', () {
      const style = MonthDayCellStyle.full;
      const cellHeight = 100.0;
      
      final heightFor3 = calendarMonthEventBarHeight(
        cellHeight: cellHeight,
        style: style,
        visibleEventCount: 3,
      );
      
      final heightFor4 = calendarMonthEventBarHeight(
        cellHeight: cellHeight,
        style: style,
        visibleEventCount: 4,
      );

      // 4 events should span an extra 3.0px (cellPadding.bottom) across the cell
      expect(heightFor4 * 4 + 3, equals(heightFor3 * 4 + 3 + style.cellPadding.bottom));
    });
  });
}

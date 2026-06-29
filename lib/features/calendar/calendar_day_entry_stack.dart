import 'package:flutter/material.dart';
import 'package:voyager/features/calendar/calendar_day_entries.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

/// Renders one entry in a month day cell stack.
class CalendarDayEntryBar extends StatelessWidget {
  const CalendarDayEntryBar({
    super.key,
    required this.entry,
    required this.fontSize,
    this.height,
    this.onTap,
  });

  final CalendarDayEntry entry;
  final double fontSize;
  final double? height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bar = entry.isTodo
        ? CalendarDayTodoBar(
            marker: entry.todo!,
            fontSize: fontSize,
            height: height,
            compact: true,
          )
        : CalendarDayEventBar(
            event: entry.event!,
            fontSize: fontSize,
            height: height,
          );

    if (onTap == null) return bar;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: bar,
    );
  }
}

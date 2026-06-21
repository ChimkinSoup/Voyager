import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Formats a [DateTime] as 12-hour local time (e.g. "3:45 PM").
String formatTime12Hour(DateTime dateTime) {
  return DateFormat.jm().format(dateTime.toLocal());
}

/// Formats a [TimeOfDay] as 12-hour local time.
String formatTimeOfDay12Hour(BuildContext context, TimeOfDay time) {
  final now = DateTime.now();
  final local = DateTime(
    now.year,
    now.month,
    now.day,
    time.hour,
    time.minute,
  );
  return formatTime12Hour(local);
}

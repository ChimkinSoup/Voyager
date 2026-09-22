import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Formats a [DateTime] as 12-hour local time (e.g. "3:45 PM").
String formatTime12Hour(DateTime dateTime) {
  return DateFormat.jm().format(dateTime.toLocal());
}

/// Formats a [TimeOfDay] as 12-hour local time.
String formatTimeOfDay12Hour(BuildContext context, TimeOfDay time) {
  final now = DateTime.now();
  final local = DateTime(now.year, now.month, now.day, time.hour, time.minute);
  return formatTime12Hour(local);
}

/// Reads a time the way a person types one: "2p", "1400", "2:30 PM", "830".
///
/// An entry with no AM/PM is settled against [referenceTime]: of the two
/// readings, the one that comes soonest after it wins — at 1 PM "3" is 3 PM,
/// at 4 PM it is 3 AM. The date always comes from [referenceTime], so the
/// earlier-in-the-day reading stays on that same day rather than rolling
/// forward. Returns null when the text is not yet a time.
DateTime? parseTimeQuery(String query, DateTime referenceTime) {
  query = query.toLowerCase().trim();
  if (query.isEmpty) return null;

  final clean = query.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (clean.isEmpty) return null;

  bool? isPM;
  if (clean.endsWith('pm') || clean.endsWith('p')) {
    isPM = true;
  } else if (clean.endsWith('am') || clean.endsWith('a')) {
    isPM = false;
  }

  String numPart = clean.replaceAll(RegExp(r'[a-z]'), '');
  if (numPart.isEmpty) return null;

  int hour = 0;
  int minute = 0;

  if (numPart.length <= 2) {
    hour = int.parse(numPart);
    minute = 0;
  } else if (numPart.length == 3) {
    hour = int.parse(numPart.substring(0, 1));
    minute = int.parse(numPart.substring(1, 3));
  } else if (numPart.length == 4) {
    hour = int.parse(numPart.substring(0, 2));
    minute = int.parse(numPart.substring(2, 4));
  } else {
    return null;
  }

  if (minute > 59) return null;

  if (hour > 12 && isPM == null) {
    if (hour > 23) return null;
    return DateTime(
      referenceTime.year,
      referenceTime.month,
      referenceTime.day,
      hour,
      minute,
    );
  }

  if (hour > 12) return null;

  if (isPM != null) {
    int h24 = hour % 12;
    if (isPM) h24 += 12;
    return DateTime(
      referenceTime.year,
      referenceTime.month,
      referenceTime.day,
      h24,
      minute,
    );
  } else {
    int h24 = hour % 12;
    int t1 = h24;
    int t2 = h24 + 12;

    double refH = referenceTime.hour + referenceTime.minute / 60.0;
    double t1Diff = (t1 + (minute / 60.0) - refH + 24) % 24;
    double t2Diff = (t2 + (minute / 60.0) - refH + 24) % 24;

    if (t1Diff < t2Diff) {
      return DateTime(
        referenceTime.year,
        referenceTime.month,
        referenceTime.day,
        t1,
        minute,
      );
    } else {
      return DateTime(
        referenceTime.year,
        referenceTime.month,
        referenceTime.day,
        t2,
        minute,
      );
    }
  }
}

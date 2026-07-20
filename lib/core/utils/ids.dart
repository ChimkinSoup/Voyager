import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

DateTime utcNow() => DateTime.now().toUtc();

/// Stable identifier for a tracker's value in a given period.
///
/// Derived from the tracker and the canonical period-start *date* (year-
/// month-day), not a wall-clock instant. This keeps a value's identity tied
/// to the calendar date it represents rather than the millisecond it was
/// first written, so the same tracker+date always maps to the same row
/// regardless of device timezone or which view (daily/weekly/monthly/yearly)
/// recorded it. Two views editing the same calendar date therefore upsert
/// one row instead of creating duplicates.
String trackerValueId(String trackerId, DateTime periodStart) {
  final month = periodStart.month.toString().padLeft(2, '0');
  final day = periodStart.day.toString().padLeft(2, '0');
  return '${trackerId}_${periodStart.year}-$month-$day';
}

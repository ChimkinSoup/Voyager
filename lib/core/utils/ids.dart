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

/// Stable identifier for one device's net change to a counter on [day].
///
/// One row per device rather than per day: each device only ever adds to its
/// own row, so two devices tapping the same day offline can't overwrite each
/// other's taps when the higher version wins the merge.
String counterAdjustmentId(String trackerId, DateTime day, String deviceId) =>
    '${trackerValueId(trackerId, day)}_$deviceId';

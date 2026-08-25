// Where a weekly tracker value gets filed.
//
// Two rules meet here, and both used to be broken in ways that read as data
// loss rather than as arithmetic:
//
//  * [PeriodicPromptService.periodStartFor]'s weekly branch subtracted a
//    `Duration`, which is elapsed time rather than calendar days. Across a DST
//    spring-forward that lands at 23:00 on the day *before* the intended one,
//    and every downstream y/m/d read floors onto that earlier date.
//  * The anchor itself followed the `weekStartsOnMonday` *display* setting, so
//    flipping a per-device preference repartitioned stored data — every lookup
//    moved by a day while the rows stayed put.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';

void main() {
  final service = PeriodicPromptService();

  group('periodStartFor weekly', () {
    // The concrete failure. In a zone that springs forward at 02:00 on Sunday
    // 2026-03-08 (America/New_York among them), the old
    // `.subtract(Duration(days: 6))` from Saturday 2026-03-14 lands on
    // 2026-03-07T23:00 — a *Saturday* — and the week is filed one day early.
    // A row written that way is still in the wild; see the schema-89 repair.
    test('a spring-forward week keeps its own start date', () {
      final start = service.periodStartFor(
        DateTime(2026, 3, 14),
        TrackerCadence.weekly,
        weekStartsMonday: false,
      );

      expect(start, DateTime(2026, 3, 8));
    });

    // The same defect stated so it holds in any zone: a period start is always
    // local midnight on the anchor weekday, never 23:00 the day before.
    test('every day of a year lands on local midnight of its anchor day', () {
      for (final mondayAnchored in [true, false]) {
        final expectedWeekday =
            mondayAnchored ? DateTime.monday : DateTime.sunday;
        for (var day = 0; day < 366; day++) {
          final date = DateTime(2026, 1, 1 + day);
          final start = service.periodStartFor(
            date,
            TrackerCadence.weekly,
            weekStartsMonday: mondayAnchored,
          );

          expect(
            start.hour,
            0,
            reason: '$date resolved to $start, not local midnight',
          );
          expect(
            start.weekday,
            expectedWeekday,
            reason: '$date resolved to $start, the wrong weekday',
          );
        }
      }
    });

    test('all seven days of a DST week resolve to one start', () {
      final starts = {
        for (var day = 0; day < 7; day++)
          service.periodStartFor(
            DateTime(2026, 3, 8 + day),
            TrackerCadence.weekly,
            weekStartsMonday: false,
          ),
      };

      expect(starts, {DateTime(2026, 3, 8)});
    });
  });

  group('trackerPeriodStartFor', () {
    // The storage anchor is Monday whatever the display setting says, because
    // a value's row id and periodStart are both derived from it and every
    // lookup matches on that exact date.
    test('anchors weekly values to Monday', () {
      for (var day = 0; day < 7; day++) {
        final start = service.trackerPeriodStartFor(
          DateTime(2026, 6, 15 + day),
          TrackerCadence.weekly,
        );

        expect(start, DateTime(2026, 6, 15));
        expect(start.weekday, DateTime.monday);
      }
    });

    test('is unaffected by the display anchor', () {
      expect(kTrackerStorageWeekStartsMonday, isTrue);

      final stored = service.trackerPeriodStartFor(
        DateTime(2026, 3, 14),
        TrackerCadence.weekly,
      );
      final sundayDisplay = service.periodStartFor(
        DateTime(2026, 3, 14),
        TrackerCadence.weekly,
        weekStartsMonday: false,
      );

      // The two deliberately disagree — that is the whole point of splitting
      // them. What must not happen is storage following the display choice.
      expect(stored, DateTime(2026, 3, 9));
      expect(sundayDisplay, DateTime(2026, 3, 8));
    });

    test('leaves the other cadences alone', () {
      expect(
        service.trackerPeriodStartFor(
          DateTime(2026, 3, 14),
          TrackerCadence.daily,
        ),
        DateTime(2026, 3, 14),
      );
      expect(
        service.trackerPeriodStartFor(
          DateTime(2026, 3, 14),
          TrackerCadence.monthly,
        ),
        DateTime(2026, 3, 1),
      );
      expect(
        service.trackerPeriodStartFor(
          DateTime(2026, 3, 14),
          TrackerCadence.yearly,
        ),
        DateTime(2026, 1, 1),
      );
    });
  });

  // `missedPeriods` walks forward one period at a time from the last completed
  // one, so the same elapsed-time arithmetic drifted its cursor across a
  // transition and produced dates a day early.
  group('missedPeriods', () {
    test('daily periods stay on calendar days across a DST transition', () {
      final missed = service.missedPeriods(
        cadence: TrackerCadence.daily,
        now: DateTime(2026, 3, 11, 9),
        lastCompleted: DateTime(2026, 3, 6, 9),
      );

      expect(missed, [
        DateTime(2026, 3, 7),
        DateTime(2026, 3, 8),
        DateTime(2026, 3, 9),
        DateTime(2026, 3, 10),
        DateTime(2026, 3, 11),
      ]);
    });
  });
}

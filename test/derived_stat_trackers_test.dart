import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';

JournalEntry _entry(String id, DateTime entryDate, {String body = ''}) {
  final now = DateTime.utc(2026, 1, 1);
  return JournalEntry(
    id: id,
    createdAt: now,
    updatedAt: now,
    journalId: 'j1',
    title: '',
    body: body,
    entryDate: entryDate,
  );
}

/// Values keyed by day, for asserting on a specific date without depending on
/// the length of the series (which runs through to today).
Map<DateTime, int> _byDay(List<TrackerValue> values) => {
  for (final v in values) v.periodStart: v.intValue!,
};

void main() {
  final analytics = AnalyticsService();

  group('buildStreakTracker / buildWordCountTracker', () {
    test('are virtual daily integer consecutive trackers', () {
      for (final tracker in [
        buildStreakTracker(colorValue: 0xFF112233),
        buildWordCountTracker(colorValue: 0xFF112233),
      ]) {
        expect(tracker.isDefault, isTrue);
        expect(tracker.type, TrackerType.integer);
        expect(tracker.cadence, TrackerCadence.daily);
        expect(tracker.effectiveTrackingStyle, TrackerStyle.consecutive);
        expect(tracker.colorValue, 0xFF112233);
      }
    });

    test('use their reserved ids', () {
      expect(buildStreakTracker(colorValue: 0).id, kStreakTrackerId);
      expect(buildWordCountTracker(colorValue: 0).id, kWordCountTrackerId);
    });
  });

  group('streakTrackerValues', () {
    test('counts consecutive journaled days and resets to 0 on a gap', () {
      final values = streakTrackerValues([
        _entry('a', DateTime(2026, 7, 1)),
        _entry('b', DateTime(2026, 7, 2)),
        _entry('c', DateTime(2026, 7, 3)),
        // 4th and 5th skipped — the streak breaks here.
        _entry('d', DateTime(2026, 7, 6)),
        _entry('e', DateTime(2026, 7, 7)),
      ]);
      final byDay = _byDay(values);
      expect(byDay[DateTime(2026, 7, 1)], 1);
      expect(byDay[DateTime(2026, 7, 2)], 2);
      expect(byDay[DateTime(2026, 7, 3)], 3);
      expect(byDay[DateTime(2026, 7, 4)], 0);
      expect(byDay[DateTime(2026, 7, 5)], 0);
      expect(byDay[DateTime(2026, 7, 6)], 1);
      expect(byDay[DateTime(2026, 7, 7)], 2);
    });

    test('treats multiple entries on one day as a single streak day', () {
      final values = streakTrackerValues([
        _entry('a', DateTime(2026, 7, 1, 9)),
        _entry('b', DateTime(2026, 7, 1, 21)),
        _entry('c', DateTime(2026, 7, 2, 10)),
      ]);
      final byDay = _byDay(values);
      expect(byDay[DateTime(2026, 7, 1)], 1);
      expect(byDay[DateTime(2026, 7, 2)], 2);
    });

    test('emits an unbroken daily series through to today', () {
      final values = streakTrackerValues([
        _entry('a', DateTime(2026, 7, 1)),
        _entry('b', DateTime(2026, 7, 4)),
      ]);
      // No missing days anywhere in the range.
      for (var i = 1; i < values.length; i++) {
        expect(
          values[i].periodStart.difference(values[i - 1].periodStart).inDays,
          1,
        );
      }
      expect(values.first.periodStart, DateTime(2026, 7, 1));
      expect(values.every((v) => v.trackerId == kStreakTrackerId), isTrue);
    });

    test('is empty when there are no entries', () {
      expect(streakTrackerValues(const []), isEmpty);
    });
  });

  group('wordCountTrackerValues', () {
    test('sums words across every entry on the same day', () {
      final values = wordCountTrackerValues([
        _entry('a', DateTime(2026, 7, 1), body: 'one two three'),
        _entry('b', DateTime(2026, 7, 1), body: 'four five'),
        _entry('c', DateTime(2026, 7, 2), body: 'lonely'),
      ], countWords: analytics.countWords);
      final byDay = _byDay(values);
      expect(byDay[DateTime(2026, 7, 1)], 5);
      expect(byDay[DateTime(2026, 7, 2)], 1);
    });

    test('scores days with no entry as 0', () {
      final values = wordCountTrackerValues([
        _entry('a', DateTime(2026, 7, 1), body: 'hello world'),
        _entry('b', DateTime(2026, 7, 4), body: 'again'),
      ], countWords: analytics.countWords);
      final byDay = _byDay(values);
      expect(byDay[DateTime(2026, 7, 2)], 0);
      expect(byDay[DateTime(2026, 7, 3)], 0);
      expect(byDay[DateTime(2026, 7, 4)], 1);
    });

    test('scores an empty body as 0 rather than 1', () {
      final values = wordCountTrackerValues([
        _entry('a', DateTime(2026, 7, 1), body: '   '),
      ], countWords: analytics.countWords);
      expect(_byDay(values)[DateTime(2026, 7, 1)], 0);
    });

    test('is empty when there are no entries', () {
      expect(
        wordCountTrackerValues(const [], countWords: analytics.countWords),
        isEmpty,
      );
    });
  });
}

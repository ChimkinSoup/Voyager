import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

JournalEntry _entry(String id, DateTime entryDate) {
  final now = DateTime.utc(2026, 1, 1);
  return JournalEntry(
    id: id,
    createdAt: now,
    updatedAt: now,
    journalId: 'j1',
    title: '',
    body: '',
    entryDate: entryDate,
  );
}

void main() {
  test('buildJournalEntriesTracker is a virtual daily boolean tracker', () {
    final tracker = buildJournalEntriesTracker(colorValue: 0xFF112233);
    expect(tracker.id, kJournalEntriesTrackerId);
    expect(tracker.isDefault, isTrue);
    expect(tracker.type, TrackerType.boolean);
    expect(tracker.cadence, TrackerCadence.daily);
    expect(tracker.colorValue, 0xFF112233);
  });

  test('journalEntriesTrackerValues emits one true value per entry day', () {
    final values = journalEntriesTrackerValues([
      _entry('a', DateTime(2026, 7, 10, 8)),
      _entry('b', DateTime(2026, 7, 11, 23)),
    ]);
    expect(values.length, 2);
    expect(values.every((v) => v.boolValue == true), isTrue);
    expect(
      values.every((v) => v.trackerId == kJournalEntriesTrackerId),
      isTrue,
    );
    final days = values.map((v) => v.periodStart).toSet();
    expect(days, {DateTime(2026, 7, 10), DateTime(2026, 7, 11)});
  });

  test('journalEntriesTrackerValues dedupes multiple entries on one day', () {
    final values = journalEntriesTrackerValues([
      _entry('a', DateTime(2026, 7, 10, 6)),
      _entry('b', DateTime(2026, 7, 10, 20)),
      _entry('c', DateTime(2026, 7, 10)),
    ]);
    expect(values.length, 1);
    expect(values.single.periodStart, DateTime(2026, 7, 10));
  });

  test('journalEntriesTrackerValues is empty when there are no entries', () {
    expect(journalEntriesTrackerValues(const []), isEmpty);
  });
}

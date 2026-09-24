// The On this day matcher (ON_THIS_DAY_HLD.md §4): which past entries a given
// local day brings back. Pure, so every rule is a plain table check.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/on_this_day.dart';

final _created = DateTime.utc(2020, 1, 1);

Journal _journal(
  String id, {
  OnThisDayCadence cadence = OnThisDayCadence.monthlyAndYearly,
  bool includeInAllView = true,
  DateTime? deletedAt,
}) => Journal(
  id: id,
  name: id,
  createdAt: _created,
  updatedAt: _created,
  onThisDayCadence: cadence,
  includeInAllView: includeInAllView,
  deletedAt: deletedAt,
);

var _nextId = 0;

/// An entry written at noon local time on [y]-[m]-[d], stored in UTC the way
/// the app stores it.
JournalEntry _entry(
  int y,
  int m,
  int d, {
  String journalId = 'j',
  String title = 'Title',
  String body = 'Body',
  DateTime? deletedAt,
  DateTime? localTime,
}) {
  final id = 'e${_nextId++}';
  final local = localTime ?? DateTime(y, m, d, 12);
  return JournalEntry(
    id: id,
    journalId: journalId,
    title: title,
    body: body,
    entryDate: local.toUtc(),
    createdAt: local.toUtc(),
    updatedAt: local.toUtc(),
    deletedAt: deletedAt,
  );
}

/// The `yyyy-MM-dd` local days that [today] brings back from [entries].
List<String> _days(
  DateTime today,
  List<JournalEntry> entries, {
  List<Journal>? journals,
  String? journalId,
}) => [
  for (final match in matchOnThisDay(
    today,
    journals ?? [_journal('j')],
    entries,
    journalId: journalId,
  ))
    '${match.localDate.year}-${match.localDate.month}-${match.localDate.day}',
];

void main() {
  group('the HLD worked examples', () {
    test('2026-09-24: Sep 24 of past years, and 2026-08-24', () {
      final entries = [
        _entry(2025, 9, 24),
        _entry(2024, 9, 24),
        _entry(2026, 8, 24),
        _entry(2026, 8, 25),
        _entry(2026, 7, 24),
        _entry(2025, 8, 24),
        _entry(2026, 9, 24),
      ];
      expect(_days(DateTime(2026, 9, 24), entries), [
        '2026-8-24',
        '2025-9-24',
        '2024-9-24',
      ]);
    });

    test('2027-02-28 (non-leap): Feb 28 and 29 of past years, Jan 28–31', () {
      final entries = [
        _entry(2024, 2, 29),
        _entry(2025, 2, 28),
        _entry(2027, 1, 27),
        _entry(2027, 1, 28),
        _entry(2027, 1, 29),
        _entry(2027, 1, 30),
        _entry(2027, 1, 31),
      ];
      expect(_days(DateTime(2027, 2, 28), entries), [
        '2027-1-31',
        '2027-1-30',
        '2027-1-29',
        '2027-1-28',
        '2025-2-28',
        '2024-2-29',
      ]);
    });

    test('2026-04-30: Apr 30 of past years, and Mar 30 and 31', () {
      final entries = [
        _entry(2025, 4, 30),
        _entry(2026, 3, 29),
        _entry(2026, 3, 30),
        _entry(2026, 3, 31),
      ];
      expect(_days(DateTime(2026, 4, 30), entries), [
        '2026-3-31',
        '2026-3-30',
        '2025-4-30',
      ]);
    });

    test('2026-03-31: Mar 31 of past years and nothing monthly', () {
      final entries = [
        _entry(2025, 3, 31),
        _entry(2026, 2, 28),
        _entry(2024, 2, 29),
      ];
      expect(_days(DateTime(2026, 3, 31), entries), ['2025-3-31']);
    });

    test('2026-01-15: Jan 15 of past years, and 2025-12-15', () {
      final entries = [
        _entry(2025, 1, 15),
        _entry(2025, 12, 15),
        _entry(2024, 12, 15),
      ];
      expect(_days(DateTime(2026, 1, 15), entries), [
        '2025-12-15',
        '2025-1-15',
      ]);
    });
  });

  test('Feb 29 shows on Feb 28 in a non-leap year only', () {
    final leapDay = [_entry(2024, 2, 29)];
    expect(_days(DateTime(2027, 2, 28), leapDay), ['2024-2-29']);
    expect(_days(DateTime(2028, 2, 28), leapDay), isEmpty);
    expect(_days(DateTime(2028, 2, 29), leapDay), ['2024-2-29']);
  });

  test('monthly wraps December into January', () {
    expect(_days(DateTime(2026, 1, 31), [_entry(2025, 12, 31)]), [
      '2025-12-31',
    ]);
  });

  test('matches on the local day, not the UTC one', () {
    // 23:30 local is already the next day in UTC anywhere east of it.
    final lateNight = _entry(
      2025,
      9,
      24,
      localTime: DateTime(2025, 9, 24, 23, 30),
    );
    expect(_days(DateTime(2026, 9, 24), [lateNight]), ['2025-9-24']);
    expect(_days(DateTime(2026, 9, 25), [lateNight]), isEmpty);
  });

  test('yearly cadence leaves out the month-ago entry', () {
    final entries = [_entry(2025, 9, 24), _entry(2026, 8, 24)];
    expect(
      _days(
        DateTime(2026, 9, 24),
        entries,
        journals: [_journal('j', cadence: OnThisDayCadence.yearly)],
      ),
      ['2025-9-24'],
    );
  });

  group('eligibility', () {
    final today = DateTime(2026, 9, 24);

    test('soft-deleted entries are left out', () {
      expect(_days(today, [_entry(2025, 9, 24, deletedAt: _created)]), isEmpty);
    });

    test('blank entries are left out; a title or a body alone is enough', () {
      expect(
        _days(today, [
          _entry(2025, 9, 24, title: ' ', body: '\n '),
          _entry(2024, 9, 24, title: '', body: 'body'),
          _entry(2023, 9, 24, title: 'title', body: ''),
        ]),
        ['2024-9-24', '2023-9-24'],
      );
    });

    test('deleted and off journals are left out', () {
      final entries = [
        _entry(2025, 9, 24, journalId: 'deleted'),
        _entry(2024, 9, 24, journalId: 'off'),
        _entry(2023, 9, 24, journalId: 'on'),
        _entry(2022, 9, 24, journalId: 'missing'),
      ];
      expect(
        _days(
          today,
          entries,
          journals: [
            _journal('deleted', deletedAt: _created),
            _journal('off', cadence: OnThisDayCadence.off),
            _journal('on'),
          ],
        ),
        ['2023-9-24'],
      );
    });

    test('the All scope drops journals kept out of the All view', () {
      final journals = [
        _journal('shown'),
        _journal('private', includeInAllView: false),
      ];
      final entries = [
        _entry(2025, 9, 24, journalId: 'shown'),
        _entry(2024, 9, 24, journalId: 'private'),
      ];
      expect(_days(today, entries, journals: journals), ['2025-9-24']);
      // Viewed on its own, the private journal still gets its memories.
      expect(_days(today, entries, journals: journals, journalId: 'private'), [
        '2024-9-24',
      ]);
    });
  });

  test('newest day first, then latest written within a day', () {
    final early = _entry(2025, 9, 24, localTime: DateTime(2025, 9, 24, 8));
    final late = _entry(2025, 9, 24, localTime: DateTime(2025, 9, 24, 20));
    final older = _entry(2020, 9, 24);
    final ids = matchOnThisDay(
      DateTime(2026, 9, 24),
      [_journal('j')],
      [older, early, late],
    ).map((m) => m.entry.id);
    expect(ids, [late.id, early.id, older.id]);
  });

  test('labels carry the distance and the entry date', () {
    final matches = matchOnThisDay(
      DateTime(2027, 2, 28),
      [_journal('j')],
      [_entry(2027, 1, 31), _entry(2026, 2, 28), _entry(2024, 2, 29)],
    );
    expect(matches.map((m) => m.label), [
      '1 month ago · Jan 31',
      '1 year ago · Feb 28',
      '3 years ago · Feb 29',
    ]);
    expect(matches.map((m) => m.shortAgo), ['1mo', '1y', '3y']);
  });

  test('dismissal keys are per entry and dated', () {
    expect(
      onThisDayDismissalKey('abc', DateTime(2026, 9, 4)),
      'abc|2026-09-04',
    );
  });
}

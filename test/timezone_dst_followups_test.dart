// Day arithmetic and ordering that broke across DST changes or mixed UTC
// offsets (timezone audit, 2026-10-22).
//
// Mar 14 2027 is a US spring-forward and Nov 1 2026 a fall-back; the
// assertions hold in any zone, DST or not. The journal ordering case needs a
// zone west of UTC to misorder under text comparison, but passes everywhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';

ForecastPeriod _period(DateTime time, double tempC) => ForecastPeriod(
  time: time,
  tempC: tempC,
  pop: 0,
  icon: 'clear',
  conditionCode: 800,
  description: 'clear',
);

void main() {
  test('a problem due in two days reads 2 across a spring-forward', () {
    final created = DateTime.utc(2027);
    final problem = LeetCodeProblem(
      id: 'p',
      createdAt: created,
      updatedAt: created,
      title: 'Two Sum',
      difficulty: LeetCodeDifficulty.easy,
      solvedAt: created,
      dueAt: DateTime(2027, 3, 16, 9),
    );
    expect(leetCodeDaysUntilDue(problem, now: DateTime(2027, 3, 14, 10)), 2);
  });

  test('daysInMonth counts every month in full', () {
    expect(daysInMonth(2027, 2), 28);
    expect(daysInMonth(2028, 2), 29);
    expect(daysInMonth(2027, 3), 31);
    expect(daysInMonth(2026, 10), 31);
    expect(daysInMonth(2026, 12), 31);
  });

  test(
    "a spring-forward day's midnight slot is its own, not the next day's",
    () {
      final periods = [
        for (var h = 0; h < 30; h += 3)
          _period(DateTime(2027, 3, 14, h), h.toDouble()),
      ];
      final day = periodsForDay(periods, DateTime(2027, 3, 14));
      for (final p in day) {
        expect(p.time.day, 14, reason: 'slot from ${p.time}');
      }
    },
  );

  test('journal entries list newest first across mixed offset forms', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftJournalRepository(db);
    final t0 = DateTime.utc(2026, 10, 1);
    JournalEntry entry(String id, DateTime at) => JournalEntry(
      id: id,
      createdAt: t0,
      updatedAt: t0,
      journalId: 'j',
      title: id,
      body: '',
      entryDate: at,
    );
    // Stored as `… -04:00` style local text and as `…Z` (what a pull or a
    // Trash restore writes); the later instant has the smaller text west of
    // UTC.
    await repo.upsertEntry(entry('older', DateTime.utc(2026, 10, 22, 1)));
    await repo.upsertEntry(
      entry('newer', DateTime.utc(2026, 10, 22, 1, 30).toLocal()),
    );
    final listed = await repo.listEntries(journalId: 'j');
    expect(listed.map((e) => e.id), ['newer', 'older']);
  });
}

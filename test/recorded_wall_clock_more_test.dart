// Option b extended (timezone audit, 2026-10-22): calendar events keep their
// wall-clock day and time wherever they are read, so their exception dates
// and done marks keep naming the occurrences they were set on; task ticks
// and LeetCode solves keep the offset they were made at.
//
// Offsets are other zones' (Tokyo +9), so the assertions say the same thing
// on a machine in any zone; on one west of Tokyo by more than eight hours
// (the Americas) the calendar case fails without the fix.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';

final _t0 = DateTime.utc(2026, 10, 1);
const _tokyo = 9 * 60;

CalendarEvent _event({
  required DateTime start,
  required DateTime end,
  int? offset,
  RecurrenceRule recurrence = RecurrenceRule.none,
  List<DateTime> exceptionDates = const [],
}) => CalendarEvent(
  id: 'ev',
  createdAt: _t0,
  updatedAt: _t0,
  calendarId: 'c',
  title: 'Gym',
  start: start,
  end: end,
  utcOffsetMinutes: offset,
  isFullDay: false,
  recurrence: recurrence,
  exceptionDates: exceptionDates,
);

void main() {
  group('calendar events', () {
    late AppDatabase db;
    late DriftCalendarRepository repo;
    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftCalendarRepository(db);
    });
    tearDown(() => db.close());

    test('a weekly 8 AM event set in Tokyo keeps its day, its time and its '
        'deleted occurrence', () async {
      // Thu Oct 22, 8 AM in Tokyo: still Wednesday in the Americas.
      await repo.upsertEvent(
        _event(
          start: DateTime(2026, 10, 22, 8),
          end: DateTime(2026, 10, 22, 9),
          offset: _tokyo,
          recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
          exceptionDates: [DateTime(2026, 10, 29)],
        ),
      );
      final event = (await repo.listEvents()).single;
      expect(event.start, DateTime(2026, 10, 22, 8));
      expect(event.utcOffsetMinutes, _tokyo);
      expect(calendarEventOccursOnDay(event, DateTime(2026, 10, 22)), isTrue);
      expect(
        calendarEventOccursOnDay(event, DateTime(2026, 10, 29)),
        isFalse,
        reason: 'the deleted occurrence stays deleted',
      );
      expect(calendarEventOccursOnDay(event, DateTime(2026, 10, 28)), isFalse);
      expect(calendarEventOccursOnDay(event, DateTime(2026, 11, 5)), isTrue);
    });

    test('both ends are stored at the start offset', () async {
      await repo.upsertEvent(
        _event(
          start: DateTime(2026, 10, 31, 10),
          end: DateTime(2026, 11, 2, 10),
          offset: _tokyo,
        ),
      );
      final event = (await repo.listEvents()).single;
      expect(event.end, DateTime(2026, 11, 2, 10));
      final data = calendarEventToFirestore(event);
      expect(data['start'], '2026-10-31T10:00:00.000+09:00');
      expect(data['end'], '2026-11-02T10:00:00.000+09:00');
    });

    test('a new start without an offset is on this device clock', () {
      final event = _event(
        start: DateTime(2026, 10, 22, 8),
        end: DateTime(2026, 10, 22, 9),
        offset: _tokyo,
      );
      expect(event.copyWith(title: 'x').utcOffsetMinutes, _tokyo);
      expect(
        event.copyWith(start: DateTime(2026, 10, 23, 8)).utcOffsetMinutes,
        isNull,
      );
    });
  });

  group('schema 166 migration', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_events_166_test');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'a multi-day event across a DST change still ends at its hour',
      () async {
        final seed = AppDatabase(NativeDatabase(file));
        await DriftCalendarRepository(seed).upsertEvent(
          _event(start: DateTime(2026, 10, 31, 10), end: DateTime(2026, 11, 2)),
        );
        // As builds before 166 left it: each end at its own offset, Eastern
        // summer time at the start and winter time at the end.
        await seed.customStatement(
          'UPDATE calendar_events_table SET start = ?, "end" = ?, '
          'utc_offset_minutes = NULL',
          ['2026-10-31T10:00:00.000 -04:00', '2026-11-02T10:00:00.000 -05:00'],
        );
        await seed.customStatement('PRAGMA user_version = 165');
        await seed.close();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);
        final event = (await DriftCalendarRepository(db).listEvents()).single;
        expect(event.utcOffsetMinutes, -4 * 60);
        expect(event.start, DateTime(2026, 10, 31, 10));
        expect(event.end, DateTime(2026, 11, 2, 10));
      },
    );
  });

  test('a tick keeps the offset it was made at, through the database and '
      'the cloud', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftTodoRepository(db);
    final task = TodoTask(
      id: 't',
      createdAt: _t0,
      updatedAt: _t0,
      listId: 'l',
      title: 't',
    ).copyWith(completed: true);
    expect(
      task.completedUtcOffsetMinutes,
      DateTime.now().timeZoneOffset.inMinutes,
    );
    await repo.upsertTask(task.copyWith(bumpVersion: false));
    final read = (await repo.getTask('t'))!;
    expect(read.completedUtcOffsetMinutes, task.completedUtcOffsetMinutes);
    final data = todoTaskToFirestore(read);
    expect(
      firestoreRecordedOffset(data['completedAt']),
      task.completedUtcOffsetMinutes,
    );
    expect(
      mergeTodoTaskFromRemote(data, 't').completedUtcOffsetMinutes,
      task.completedUtcOffsetMinutes,
    );
    expect(read.copyWith(completed: false).completedUtcOffsetMinutes, isNull);
  });

  test("a problem solved late in Tokyo stays on Tokyo's day", () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftLeetCodeRepository(db);
    await repo.upsertProblem(
      LeetCodeProblem(
        id: 'p',
        createdAt: _t0,
        updatedAt: _t0,
        title: 'Two Sum',
        difficulty: LeetCodeDifficulty.easy,
        solvedAt: DateTime(2026, 10, 22, 23, 30),
        utcOffsetMinutes: _tokyo,
      ),
    );
    final read = (await repo.listProblems()).single;
    expect(read.solvedAt, DateTime(2026, 10, 22, 23, 30));
    final data = leetCodeProblemToFirestore(read);
    expect(data['solvedAt'], '2026-10-22T23:30:00.000+09:00');
    expect(
      mergeLeetCodeProblemFromRemote(data, 'p').solvedAt,
      DateTime(2026, 10, 22, 23, 30),
    );
  });
}

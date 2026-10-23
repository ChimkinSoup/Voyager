// Journal and dream entries, transactions and room events keep the day and
// time they were written at, wherever they are read: each carries the
// writing device's UTC offset beside its instant (timezone audit, Option b,
// 2026-10-22).
//
// Offsets here are other zones' (Tokyo +9, Vancouver −7), so the assertions
// say the same thing on a machine in any zone.

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';

final _t0 = DateTime.utc(2026, 10, 1);
const _tokyo = 9 * 60;
const _vancouver = -7 * 60;

JournalEntry _entry(String id, DateTime at, {int? offset}) => JournalEntry(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  journalId: 'j',
  title: id,
  body: '',
  entryDate: at,
  utcOffsetMinutes: offset,
);

void main() {
  group('recordedWallClock', () {
    test('reads an instant on the clock of the zone that recorded it', () {
      // 14:30 UTC was 23:30 in Tokyo.
      expect(
        recordedWallClock(DateTime.utc(2026, 10, 22, 14, 30), _tokyo),
        DateTime(2026, 10, 22, 23, 30),
      );
      expect(
        recordedInstant(DateTime(2026, 10, 22, 23, 30), _tokyo),
        DateTime.utc(2026, 10, 22, 14, 30),
      );
    });

    test('a time this device skips keeps its moment through a save', () {
      // 02:30 on Mar 14 2027 in UTC — a time US clocks skip that night. In
      // a zone without that gap the value is simply 02:30.
      final instant = DateTime.utc(2027, 3, 14, 2, 30);
      final wall = recordedWallClock(instant, 0);
      expect(recordedInstant(wall, 0), instant);
    });

    test('without an offset, reads in this device zone as before', () {
      final instant = DateTime.utc(2026, 10, 22, 14, 30);
      expect(recordedWallClock(instant, null), instant.toLocal());
    });
  });

  group('journal entries', () {
    late AppDatabase db;
    late DriftJournalRepository repo;
    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftJournalRepository(db);
    });
    tearDown(() => db.close());

    test("an entry written late in Tokyo stays on Tokyo's day", () async {
      await repo.upsertEntry(
        _entry('late', DateTime(2026, 10, 22, 23, 30), offset: _tokyo),
      );
      final row =
          (await db
                  .customSelect(
                    'SELECT entry_date, utc_offset_minutes FROM journal_entries_table',
                  )
                  .getSingle())
              .data;
      expect(
        DateTime.parse(row['entry_date'] as String).toUtc(),
        DateTime.utc(2026, 10, 22, 14, 30),
      );
      expect(row['utc_offset_minutes'], _tokyo);

      final read = (await repo.listEntries(journalId: 'j')).single;
      expect(read.entryDate, DateTime(2026, 10, 22, 23, 30));
      expect(journalDay(read.entryDate, 0), DateTime(2026, 10, 22));
    });

    test('lists order, limit and filter by the clock each entry was written '
        'on', () async {
      // Tokyo 23:00 (14:00 UTC) is the later wall clock; Vancouver 20:00 on
      // the same date (03:00 UTC next day) the later instant.
      await repo.upsertEntry(
        _entry('tokyo', DateTime(2026, 10, 22, 23), offset: _tokyo),
      );
      await repo.upsertEntry(
        _entry('vancouver', DateTime(2026, 10, 22, 20), offset: _vancouver),
      );
      await repo.upsertEntry(
        _entry('next day', DateTime(2026, 10, 23, 1), offset: _tokyo),
      );
      final latest = await repo.listEntries(journalId: 'j', limit: 2);
      expect(latest.map((e) => e.id), ['next day', 'tokyo']);
      final oct22 = await repo.listEntries(
        journalId: 'j',
        from: DateTime(2026, 10, 22).toUtc(),
        to: DateTime(2026, 10, 22, 23, 59, 59).toUtc(),
      );
      expect(oct22.map((e) => e.id), ['tokyo', 'vancouver']);
    });

    test('an entry saved without an offset is stamped with this device '
        'one', () async {
      final now = DateTime(2026, 10, 22, 21, 15);
      await repo.upsertEntry(_entry('here', now));
      final read = (await repo.listEntries(journalId: 'j')).single;
      expect(read.utcOffsetMinutes, now.timeZoneOffset.inMinutes);
      expect(read.entryDate, now);
    });

    test('picking a new date drops the old offset; keeping it does not', () {
      final entry = _entry('e', DateTime(2026, 10, 22, 23, 30), offset: _tokyo);
      expect(
        entry.copyWith(entryDate: entry.entryDate).utcOffsetMinutes,
        _tokyo,
      );
      expect(
        entry.copyWith(entryDate: DateTime(2026, 10, 20, 9)).utcOffsetMinutes,
        isNull,
      );
    });
  });

  group('sync', () {
    test('an entry syncs its date with the offset written into it', () {
      final data = journalEntryToFirestore(
        _entry('e', DateTime(2026, 10, 22, 23, 30), offset: _tokyo),
      );
      expect(data['entryDate'], '2026-10-22T23:30:00.000+09:00');
      expect(
        DateTime.parse(data['entryDate'] as String),
        DateTime.utc(2026, 10, 22, 14, 30),
      );
    });

    test("a pulled entry reads on its writer's clock", () {
      final merged = mergeJournalEntryFromRemote({
        'journalId': 'j',
        'title': 't',
        'body': '',
        'entryDate': '2026-10-22T23:30:00.000+09:00',
        'updatedAt': _t0.toIso8601String(),
        'version': 1,
      }, 'e');
      expect(merged.entryDate, DateTime(2026, 10, 22, 23, 30));
      expect(merged.utcOffsetMinutes, _tokyo);
    });

    test("an older build's document reads in this device's zone", () {
      final instant = DateTime.utc(2026, 10, 22, 14, 30);
      final merged = mergeJournalEntryFromRemote({
        'journalId': 'j',
        'title': 't',
        'body': '',
        'entryDate': instant.toIso8601String(),
        'updatedAt': _t0.toIso8601String(),
        'version': 1,
      }, 'e');
      expect(merged.entryDate, instant.toLocal());
      expect(merged.utcOffsetMinutes, isNull);
    });

    test('an older build rewriting the date leaves no stale offset behind', () {
      // Uploads merge key by key: the older build's write replaces entryDate
      // and nothing else in a document this build wrote.
      final moved = DateTime.utc(2026, 10, 25, 1);
      final data = {
        ...journalEntryToFirestore(
          _entry('e', DateTime(2026, 10, 22, 23, 30), offset: _tokyo),
        ),
        'entryDate': moved.toIso8601String(),
      };
      final merged = mergeJournalEntryFromRemote(data, 'e');
      expect(merged.entryDate, moved.toLocal());
      expect(merged.utcOffsetMinutes, isNull);
    });
  });

  test(
    'a Dec 31 evening contribution in Vancouver stays in that year',
    () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = DriftFinanceRepository(db);
      // 23:00 on Dec 31 in Vancouver is already Jan 1 in UTC and further east.
      await repo.upsertTransaction(
        FinancialTransaction(
          id: 'tx',
          createdAt: _t0,
          updatedAt: _t0,
          type: TransactionType.deposit,
          amountCents: 10000,
          occurredAt: DateTime(2026, 12, 31, 23),
          utcOffsetMinutes: _vancouver,
        ),
      );
      final read = (await repo.listTransactions()).single;
      expect(read.occurredAt, DateTime(2026, 12, 31, 23));
      expect(read.occurredAt.year, 2026);
    },
  );

  group('schema 165 migration', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_offsets_165_test');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test("takes each entry's offset from its stored text, or this device's "
        'for a UTC one', () async {
      final seed = AppDatabase(NativeDatabase(file));
      final journal = DriftJournalRepository(seed);
      await journal.upsertEntry(_entry('wall', DateTime(2026, 10, 22, 9)));
      await journal.upsertEntry(_entry('utc', DateTime(2026, 10, 22, 10)));
      // As older builds left them: the writer's wall time and offset, and the
      // `…Z` form a pull or a Trash restore wrote.
      await seed.customStatement(
        'UPDATE journal_entries_table SET entry_date = ?, '
        'utc_offset_minutes = NULL WHERE id = ?',
        ['2026-10-22T23:30:00.000 +09:00', 'wall'],
      );
      final utc = DateTime.utc(2026, 10, 22, 14);
      await seed.customStatement(
        'UPDATE journal_entries_table SET entry_date = ?, '
        'utc_offset_minutes = NULL WHERE id = ?',
        [utc.toIso8601String(), 'utc'],
      );
      await seed.customStatement('PRAGMA user_version = 164');
      await seed.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      Future<Object?> offset(String id) async =>
          (await db
                  .customSelect(
                    'SELECT utc_offset_minutes FROM journal_entries_table WHERE id = ?',
                    variables: [Variable(id)],
                  )
                  .getSingle())
              .data['utc_offset_minutes'];
      expect(await offset('wall'), _tokyo);
      expect(await offset('utc'), utc.toLocal().timeZoneOffset.inMinutes);

      final entries = await DriftJournalRepository(db).listEntries();
      expect(
        entries.firstWhere((e) => e.id == 'wall').entryDate,
        DateTime(2026, 10, 22, 23, 30),
      );
    });
  });
}

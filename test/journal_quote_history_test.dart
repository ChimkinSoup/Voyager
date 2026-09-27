import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

void main() {
  late AppDatabase db;
  late DriftJournalRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftJournalRepository(db);
  });

  tearDown(() => db.close());

  JournalEntry entry(
    String id,
    String journalId,
    String? quoteId,
    DateTime createdAt,
  ) => JournalEntry(
    id: id,
    createdAt: createdAt,
    updatedAt: createdAt,
    journalId: journalId,
    title: '',
    body: '',
    entryDate: createdAt,
    quoteId: quoteId,
  );

  test('keeps the latest use of each quote per journal', () async {
    final day1 = DateTime.utc(2026, 9, 25);
    final day2 = DateTime.utc(2026, 9, 26);
    await repo.upsertEntry(entry('e1', 'j1', 'a', day1));
    await repo.upsertEntry(entry('e2', 'j1', 'a', day2));
    await repo.upsertEntry(entry('e3', 'j2', 'a', day1));
    await repo.upsertEntry(entry('e4', 'j1', null, day2));

    final history = await repo.lastQuoteUseByJournal();

    expect(history.keys, unorderedEquals(['j1', 'j2']));
    expect(history['j1'], {'a': day2});
    expect(history['j2'], {'a': day1});
  });

  test('reads from the quote-use index alone', () async {
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN '
          'SELECT journal_id, quote_id, MAX(created_at) '
          'FROM journal_entries_table '
          'WHERE deleted_at IS NULL AND quote_id IS NOT NULL '
          'GROUP BY journal_id, quote_id',
        )
        .get();
    expect(
      plan.map((r) => r.read<String>('detail')).join('\n'),
      contains('COVERING INDEX idx_journal_entries_quote_use'),
    );
  });
}

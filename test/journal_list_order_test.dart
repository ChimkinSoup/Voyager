// Journals were listed in SQLite row order, which after a pull is the order the
// rows arrived, so the switcher, Manage journals and the All-journals "New
// entry" fallback differed between installs (BUG-056).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

void main() {
  late AppDatabase db;
  late DriftJournalRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftJournalRepository(db);
  });

  tearDown(() => db.close());

  test(
    'journals list in creation order, whatever order rows were written',
    () async {
      final base = DateTime.utc(2026, 9, 30);
      Journal journal(String id, String name, int minutes) => Journal(
        id: id,
        name: name,
        createdAt: base.add(Duration(minutes: minutes)),
        updatedAt: base,
      );
      // Inserted as a pull might deliver them: newest first.
      await repo.upsertJournal(journal('g', 'Gamma', 2));
      await repo.upsertJournal(journal('a', 'Alpha', 1));
      await repo.upsertJournal(journal('j', 'Journal', 0));

      expect((await repo.listJournals()).map((j) => j.name), [
        'Journal',
        'Alpha',
        'Gamma',
      ]);
    },
  );
}

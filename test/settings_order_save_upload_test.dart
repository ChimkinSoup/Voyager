// The inbox order savers write settings inside a transaction. The upload they
// set off reads the database again after its network round trip — it used to
// run in the transaction's zone and find it closed by then.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;
  late List<Future<void>> uploads;

  setUp(() async {
    db = AppDatabase.inMemory();
    uploads = [];
    final syncedWrites = SyncedWriteNotifier()
      ..onWrite = (collection, records) {
        // What the upload does: wait on the network, then touch the outbox.
        uploads.add(
          Future<void>.delayed(
            const Duration(milliseconds: 10),
          ).then((_) => db.select(db.pendingUploadsTable).get()),
        );
      };
    repo = DriftSettingsRepository(db, syncedWrites: syncedWrites);
    await repo.getSettings();
  });

  tearDown(() => db.close());

  test('a tracker order save uploads outside its transaction', () async {
    await repo.saveInboxTrackerOrder(const ['b', 'a']);
    expect(uploads, hasLength(1));
    await Future.wait(uploads);
    expect((await repo.getSettings()).inboxTrackerOrder, ['b', 'a']);
  });

  test('a note order save uploads outside its transaction', () async {
    await repo.saveInboxNoteOrder(const ['b', 'a'], secure: false);
    await repo.saveInboxNoteOrder(const ['d', 'c'], secure: true);
    expect(uploads, hasLength(2));
    await Future.wait(uploads);
    final AppSettings stored = await repo.getSettings();
    expect(stored.inboxPinnedNoteOrder, ['b', 'a']);
    expect(stored.inboxSecureNoteOrder, ['d', 'c']);
  });
}

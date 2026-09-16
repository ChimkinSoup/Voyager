// Images attached while the network is flaky upload their metadata through
// the same outbox as everything else. These pin that a queued media row is
// actually re-sent, rather than cleared as if its entity were gone.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _StubAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'user-1';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.inMemory());
  tearDown(() async => db.close());

  test('a queued media reference is re-sent, not cleared', () async {
    final firestore = FakeFirebaseFirestore();
    final worker = OutboxSyncWorker(
      db,
      firestore,
      _StubAuthRepository(),
      yieldDelay: Duration.zero,
    );
    final at = DateTime.utc(2026, 9, 1);
    await DriftMediaRepository(db).upsertReference(
      MediaReference(
        id: 'ref-1',
        mediaId: 'media-1',
        collection: FirestoreCollections.journalEntries,
        documentId: 'entry-1',
        createdAt: at,
        updatedAt: at,
      ),
      recordLocalActivity: false,
    );
    await worker.enqueue(
      collection: FirestoreCollections.mediaReferences,
      documentId: 'ref-1',
    );

    await worker.startDraining();

    final snap = await firestore
        .doc('users/user-1/${FirestoreCollections.mediaReferences}/ref-1')
        .get();
    expect(snap.exists, isTrue);
  });
}

// A live listener fires for this device's own write twice: once from the local
// cache while it waits for the server, again when the server confirms it. The
// first is left out at the source; only the confirmation is ours to recognise.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';

void main() {
  group('a snapshot held back as an unconfirmed write', () {
    bool heldBack(bool hasPendingWrites, Map<String, dynamic> data) =>
        FirestoreSyncRepository.isUnconfirmedStampedWrite(
          hasPendingWrites: hasPendingWrites,
          data: data,
        );

    test('is a pending write whose write time the server has yet to fill', () {
      expect(
        heldBack(true, {'name': 'Work', '_serverWrittenAt': null}),
        isTrue,
      );
    });

    test('is not the server confirming it', () {
      expect(
        heldBack(false, {
          'name': 'Work',
          '_serverWrittenAt': DateTime.utc(2026),
        }),
        isFalse,
      );
    });

    test('is not a pending write that left the old write time alone', () {
      // The settings patch skips the stamp. Its acknowledgement changes only
      // metadata, which fires nothing, so this snapshot is the last one.
      expect(
        heldBack(true, {
          'name': 'Work',
          '_serverWrittenAt': DateTime.utc(2026),
        }),
        isFalse,
      );
      expect(heldBack(true, {'name': 'Work'}), isFalse);
    });
  });

  test('a confirmed write still reaches the listener', () async {
    final repository = FirestoreSyncRepository(
      FakeFirebaseFirestore(),
      'user-1',
      writeGate: FirestoreWriteGate(waitForPendingWrites: () async {}),
    );
    final delivered = repository
        .watchCollection('calendars')
        .firstWhere((changed) => changed.containsKey('cal-1'));

    await repository.upsertDocument('calendars', 'cal-1', {'name': 'Work'});

    expect((await delivered)['cal-1'], {'name': 'Work'});
  });

  group('a document leaving the listener query (BUG-282)', () {
    late FakeFirebaseFirestore firestore;
    late FirestoreSyncRepository repository;
    final since = DateTime.utc(2026, 1, 1);

    setUp(() {
      firestore = FakeFirebaseFirestore();
      repository = FirestoreSyncRepository(
        firestore,
        'user-1',
        writeGate: FirestoreWriteGate(waitForPendingWrites: () async {}),
      );
    });

    test('is not a deletion while the document still exists', () async {
      // Our own pending write leaves the write time unset in the cache, so the
      // document drops out of `changedSince` until the server confirms it.
      // Reported as removed, it threw away the open editor's session.
      final events = <Map<String, Map<String, dynamic>>>[];
      final sub = repository
          .watchCollection('journal_entries', changedSince: since)
          .listen(events.add);
      addTearDown(sub.cancel);
      await repository.upsertDocument('journal_entries', 'e-1', {'body': 'a'});
      await pumpEventQueue();
      await firestore.doc('users/user-1/journal_entries/e-1').update({
        '_serverWrittenAt': DateTime.utc(2025),
      });
      await pumpEventQueue();

      expect(events.where((e) => e['e-1']?.isEmpty ?? false), isEmpty);
    });

    test('is a deletion once the document is gone', () async {
      final events = <Map<String, Map<String, dynamic>>>[];
      final sub = repository
          .watchCollection('journal_entries', changedSince: since)
          .listen(events.add);
      addTearDown(sub.cancel);
      await repository.upsertDocument('journal_entries', 'e-1', {'body': 'a'});
      await pumpEventQueue();
      await firestore.doc('users/user-1/journal_entries/e-1').delete();
      await pumpEventQueue();

      expect(events.last, {'e-1': <String, dynamic>{}});
    });
  });
}

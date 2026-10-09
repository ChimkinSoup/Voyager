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
}

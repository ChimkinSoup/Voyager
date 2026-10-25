// A Gaia message too big for one Firestore document (GAIA_HLD.md §8): its
// parts travel in `gaia_message_chunks`, and come back whole on the other
// device. Two devices share one InMemorySyncRepository as the server.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';

class _Device {
  _Device(InMemorySyncRepository server, String deviceId) {
    db = AppDatabase.inMemory();
    gaia = DriftGaiaRepository(db);
    sync = RemoteSyncService(
      syncRepository: server,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      jobRepository: DriftJobRepository(db),
      rankingRepository: DriftRankingRepository(db),
      calendarRepository: DriftCalendarRepository(db),
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      photoSeriesRepository: DriftPhotoSeriesRepository(db),
      gaiaRepository: gaia,
      settingsRepository: DriftSettingsRepository(db),
      syncEngine: SyncEngine(
        syncRepository: server,
        deviceId: deviceId,
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: deviceId,
      uploadDebounceDelay: Duration.zero,
    );
  }

  late final AppDatabase db;
  late final DriftGaiaRepository gaia;
  late final RemoteSyncService sync;
}

final _now = DateTime.utc(2026, 10, 25, 12);

GaiaMessage _message(List<GaiaPart> parts) => GaiaMessage(
  id: 'm1',
  chatId: 'c1',
  seq: 1,
  role: GaiaMessageRole.assistant,
  parts: parts,
  status: GaiaMessageStatus.complete,
  createdAt: _now,
  updatedAt: _now,
);

/// Past [gaiaMessageChunkBytes], with an emoji (a surrogate pair) at every
/// position so some chunk boundary has to step around one.
List<GaiaPart> _bigParts() => [
  GaiaTextPart('a😀' * 200000),
  const GaiaActivityPart(['Bash']),
  GaiaTextPart('é' * 300000),
];

void main() {
  group('splitGaiaMessagePayload', () {
    test('parts that fit stay in the document', () {
      final split = splitGaiaMessagePayload(
        gaiaMessageToFirestore(_message(const [GaiaTextPart('hi')])),
      );
      expect(split.chunks, isEmpty);
      expect(split.document['partChunks'], 0);
      expect(split.document['parts'], isNotEmpty);
    });

    test('big parts split into chunks that each fit, and join back', () {
      final message = _message(_bigParts());
      final split = splitGaiaMessagePayload(gaiaMessageToFirestore(message));

      expect(split.chunks.length, greaterThan(1));
      expect(split.document['parts'], isEmpty);
      expect(gaiaMessagePartChunks(split.document), split.chunks.length);
      for (final chunk in split.chunks.values) {
        final text = chunk['text'] as String;
        // A lone surrogate at either end would be mangled as UTF-8.
        expect(
          text.codeUnitAt(text.length - 1),
          isNot(inInclusiveRange(0xD800, 0xDBFF)),
        );
        expect(text.codeUnitAt(0), isNot(inInclusiveRange(0xDC00, 0xDFFF)));
      }

      final back = mergeGaiaMessageFromRemote(
        joinGaiaMessageChunks(split.document, split.chunks.values.toList()),
        'm1',
      );
      expect(back.toJson(), message.toJson());
    });
  });

  group('sync', () {
    late InMemorySyncRepository server;
    late _Device a;
    late _Device b;

    setUp(() {
      server = InMemorySyncRepository();
      a = _Device(server, 'device-a');
      b = _Device(server, 'device-b');
    });

    tearDown(() async {
      await a.db.close();
      await b.db.close();
    });

    test('an oversized message reaches the other device whole', () async {
      final message = _message(_bigParts());
      await a.gaia.upsertMessage(message, recordLocalActivity: false);
      await a.sync.pushRecords(FirestoreCollections.gaiaMessages, [message]);

      final doc = await server.getDocument(
        FirestoreCollections.gaiaMessages,
        'm1',
      );
      expect(doc!['parts'], isEmpty);
      final count = gaiaMessagePartChunks(doc);
      expect(count, greaterThan(1));

      await b.sync.pullGaiaMessages();
      expect((await b.gaia.getMessage('m1'))!.toJson(), message.toJson());
    });

    test('a missing chunk fails the message rather than emptying it', () async {
      final message = _message(_bigParts());
      await a.sync.pushRecords(FirestoreCollections.gaiaMessages, [message]);
      await server.deleteDocument(
        FirestoreCollections.gaiaMessageChunks,
        gaiaMessageChunkId('m1', 1),
      );

      // Thrown like a schema failure, so the pull is asked again next time.
      await expectLater(b.sync.pullGaiaMessages(), throwsStateError);
      expect(await b.gaia.getMessage('m1'), isNull);
    });

    test('erasing an oversized message deletes its chunks', () async {
      final message = _message(_bigParts());
      await a.sync.pushRecords(FirestoreCollections.gaiaMessages, [message]);
      final count = gaiaMessagePartChunks(
        (await server.getDocument(FirestoreCollections.gaiaMessages, 'm1'))!,
      );

      final erased = message.copyWith(
        parts: const [],
        deletedAt: kErasedAt,
        version: message.version + kEraseVersionStep,
      );
      await a.sync.pushRecords(FirestoreCollections.gaiaMessages, [erased]);

      for (var n = 0; n < count; n++) {
        expect(
          await server.getDocument(
            FirestoreCollections.gaiaMessageChunks,
            gaiaMessageChunkId('m1', n),
          ),
          isNull,
        );
      }
      final doc = await server.getDocument(
        FirestoreCollections.gaiaMessages,
        'm1',
      );
      expect(gaiaMessagePartChunks(doc!), 0);
      expect(isErasedPayload(doc), isTrue);
    });

    test('purging an oversized message deletes its chunks', () async {
      final message = _message(_bigParts());
      await a.sync.pushRecords(FirestoreCollections.gaiaMessages, [message]);
      final count = gaiaMessagePartChunks(
        (await server.getDocument(FirestoreCollections.gaiaMessages, 'm1'))!,
      );

      await a.sync.permanentlyDeleteFromRemote(
        collection: FirestoreCollections.gaiaMessages,
        documentId: 'm1',
      );

      for (var n = 0; n < count; n++) {
        expect(
          await server.getDocument(
            FirestoreCollections.gaiaMessageChunks,
            gaiaMessageChunkId('m1', n),
          ),
          isNull,
        );
      }
    });
  });
}

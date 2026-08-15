import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/sync_error_classification.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

/// One character operation per character of [text], the shape a full-document
/// reseed produces.
List<CharacterOperation> opsForText(String text) {
  final session = CharacterOpSession(
    clientId: 'device-a',
    initialText: text,
    seedAsPending: true,
  );
  return session.takePendingOps();
}

SyncOperation operationDoc({
  required String id,
  required String payload,
  int sequence = 1,
  DateTime? timestamp,
}) {
  return SyncOperation(
    id: id,
    documentId: 'entry-1',
    sequence: sequence,
    payload: payload,
    deviceId: 'device-a',
    timestamp: timestamp ?? DateTime.utc(2026, 1, 1),
  );
}

int utf8Length(String value) => utf8.encode(value).length;

void main() {
  group('CharOpsPayload.intoChunks', () {
    test('keeps every chunk under the byte budget', () {
      final text = 'a' * 400;
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText(text),
        snapshot: {'body': text},
        groupId: 'group-1',
        maxPayloadBytes: 2000,
      );

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(utf8Length(chunk.encode()), lessThanOrEqualTo(2000));
      }
    });

    test('carries the snapshot in the first chunk only', () {
      final text = 'a' * 400;
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText(text),
        snapshot: {'body': text},
        groupId: 'group-1',
        maxPayloadBytes: 2000,
      );

      expect(chunks.first.snapshot, isNotNull);
      expect(chunks.skip(1).map((c) => c.snapshot), everyElement(isNull));
    });

    test('stamps every chunk with the group id, index and total', () {
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText('a' * 400),
        snapshot: null,
        groupId: 'group-1',
        maxPayloadBytes: 2000,
      );

      expect(
        chunks.map((c) => c.chunkIndex),
        List.generate(chunks.length, (i) => i),
      );
      expect(
        chunks.every(
          (c) => c.groupId == 'group-1' && c.chunkCount == chunks.length,
        ),
        isTrue,
      );
    });

    test('leaves an unsplit payload in the pre-chunking shape', () {
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText('hi'),
        snapshot: {'body': 'hi'},
        groupId: 'group-1',
        maxPayloadBytes: maxOperationPayloadBytes,
      );

      expect(chunks, hasLength(1));
      final decoded = jsonDecode(chunks.single.encode()) as Map<String, dynamic>;
      expect(decoded.containsKey(CharOpsPayload.groupIdKey), isFalse);
      expect(decoded.containsKey(CharOpsPayload.chunkCountKey), isFalse);
    });

    test('rejects a snapshot that cannot fit on its own', () {
      expect(
        () => CharOpsPayload.intoChunks(
          charOps: opsForText('hi'),
          snapshot: {'body': 'x' * 5000},
          groupId: 'group-1',
          maxPayloadBytes: 2000,
        ),
        throwsA(isA<SyncPayloadTooLargeException>()),
      );
    });

    test('round-trips through the merger to the original text', () {
      final text = List.generate(500, (i) => String.fromCharCode(97 + i % 26))
          .join();
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText(text),
        snapshot: {'body': text},
        groupId: 'group-1',
        maxPayloadBytes: 2000,
      );

      final merged = CharacterSequenceCrdtMerger().applyMergedPayload([
        for (var i = 0; i < chunks.length; i++)
          operationDoc(id: 'op_c$i', payload: chunks[i].encode()),
      ]);

      expect((jsonDecode(merged) as Map)['body'], text);
    });
  });

  group('incomplete chunk groups', () {
    test('are ignored rather than reconstructing truncated text', () {
      final established = CharOpsPayload(
        charOps: opsForText('hello'),
        snapshot: {'body': 'hello'},
      );
      final replacement = 'z' * 400;
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText(replacement),
        snapshot: {'body': replacement},
        groupId: 'group-2',
        maxPayloadBytes: 2000,
      );
      expect(chunks.length, greaterThan(2), reason: 'need a droppable chunk');

      // Everything except the final chunk landed.
      final merged = CharacterSequenceCrdtMerger().applyMergedPayload([
        operationDoc(
          id: 'op-established',
          payload: established.encode(),
          timestamp: DateTime.utc(2026, 1, 1),
        ),
        for (var i = 0; i < chunks.length - 1; i++)
          operationDoc(
            id: 'op-partial_c$i',
            payload: chunks[i].encode(),
            sequence: 2,
            timestamp: DateTime.utc(2026, 1, 2),
          ),
      ]);

      expect((jsonDecode(merged) as Map)['body'], 'hello');
    });

    test('are accepted once the missing chunk arrives', () {
      final replacement = 'z' * 400;
      final chunks = CharOpsPayload.intoChunks(
        charOps: opsForText(replacement),
        snapshot: {'body': replacement},
        groupId: 'group-2',
        maxPayloadBytes: 2000,
      );

      final merged = CharacterSequenceCrdtMerger().applyMergedPayload([
        for (var i = 0; i < chunks.length; i++)
          operationDoc(id: 'op-full_c$i', payload: chunks[i].encode()),
      ]);

      expect((jsonDecode(merged) as Map)['body'], replacement);
    });
  });

  group('sync error classification', () {
    test('treats a rejected argument as permanent', () {
      expect(
        classifySyncFailure(
          FirebaseException(plugin: 'cloud_firestore', code: 'invalid-argument'),
        ),
        SyncFailureKind.permanent,
      );
    });

    test('treats backend unavailability as transient', () {
      expect(
        classifySyncFailure(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        ),
        SyncFailureKind.transient,
      );
    });

    test('treats an oversized payload as permanent', () {
      expect(
        classifySyncFailure(
          const SyncPayloadTooLargeException(
            part: 'document snapshot',
            bytes: 2,
            maxBytes: 1,
          ),
        ),
        SyncFailureKind.permanent,
      );
    });

    test('defaults an unrecognised error to transient', () {
      expect(classifySyncFailure(StateError('nope')), SyncFailureKind.transient);
    });
  });

  group('SyncRetryPolicy', () {
    test('does not retry a permanently rejected write', () async {
      var attempts = 0;
      await expectLater(
        const SyncRetryPolicy(initialBackoff: Duration(milliseconds: 1)).run(
          () async {
            attempts++;
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'invalid-argument',
            );
          },
        ),
        throwsA(isA<FirebaseException>()),
      );
      expect(attempts, 1);
    });

    test('still retries a transient failure', () async {
      var attempts = 0;
      await expectLater(
        const SyncRetryPolicy(initialBackoff: Duration(milliseconds: 1)).run(
          () async {
            attempts++;
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'unavailable',
            );
          },
        ),
        throwsA(isA<FirebaseException>()),
      );
      expect(attempts, 3);
    });
  });

  group('SyncEngine', () {
    test('splits an oversized char-op write into one atomic group', () async {
      final repo = _RecordingSyncRepository();
      final engine = SyncEngine(
        syncRepository: repo,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
      );
      addTearDown(engine.dispose);

      // Comfortably past the real single-document ceiling once each character
      // becomes its own operation.
      final text = List.generate(9000, (i) => String.fromCharCode(97 + i % 26))
          .join();

      await engine.syncDocumentImmediately(
        collection: 'journal_entries',
        documentId: 'entry-1',
        payload: {'body': text},
        charOps: opsForText(text),
      );

      expect(repo.groupSizes, hasLength(1));
      expect(repo.groupSizes.single, greaterThan(1));

      final stored = await repo.listOperations('entry-1');
      for (final operation in stored) {
        expect(
          utf8Length(operation.payload),
          lessThanOrEqualTo(maxOperationPayloadBytes),
        );
      }

      final merged = CharacterSequenceCrdtMerger().applyMergedPayload(stored);
      expect((jsonDecode(merged) as Map)['body'], text);
    });

    test('keeps the historical single-operation shape when it fits', () async {
      final repo = _RecordingSyncRepository();
      final engine = SyncEngine(
        syncRepository: repo,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
      );
      addTearDown(engine.dispose);

      await engine.syncDocumentImmediately(
        collection: 'journal_entries',
        documentId: 'entry-1',
        payload: {'body': 'hi'},
        charOps: opsForText('hi'),
      );

      final stored = await repo.listOperations('entry-1');
      expect(stored, hasLength(1));
      // Unsplit writes carry no chunk suffix — that is what "single-operation
      // shape" means. The id also names the device and the document, but the
      // wall clock in the middle of it is deliberately not asserted here; see
      // the restart test below for what it is for.
      expect(stored.single.id, startsWith('device-a_entry-1_'));
      expect(stored.single.id, isNot(endsWith('_c0')));
    });

    test('a restart cannot mint an id that overwrites an earlier one', () async {
      final repo = _RecordingSyncRepository();

      // Two engines over one repository is exactly what closing and reopening
      // the app looks like from Firestore's side: the in-memory sequence
      // counter starts again at 0, so both sessions reach for "operation 1" of
      // the same document. `appendOperation` writes with `set`, so a shared id
      // meant the second session silently destroyed the first session's
      // characters.
      for (final session in ['first', 'second']) {
        final engine = SyncEngine(
          syncRepository: repo,
          deviceId: 'device-a',
          debouncer: Debouncer(delay: Duration.zero),
        );
        await engine.syncDocumentImmediately(
          collection: 'journal_entries',
          documentId: 'entry-1',
          payload: {'body': session},
          charOps: opsForText(session),
        );
        engine.dispose();
      }

      final stored = await repo.listOperations('entry-1');
      expect(stored, hasLength(2));
      expect(stored.map((op) => op.id).toSet(), hasLength(2));
    });

    test('a seeded sequence keeps a restart ordering after the old log', () async {
      final repo = _RecordingSyncRepository();
      final engine = SyncEngine(
        syncRepository: repo,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
      );
      addTearDown(engine.dispose);

      // What `prepareEditingSession` does with the log it has just read.
      engine.ensureSequenceAbove(41);

      await engine.syncDocumentImmediately(
        collection: 'journal_entries',
        documentId: 'entry-1',
        payload: {'body': 'hi'},
        charOps: opsForText('hi'),
      );

      final stored = await repo.listOperations('entry-1');
      expect(stored.single.sequence, 42);
    });
  });
}

class _RecordingSyncRepository extends InMemorySyncRepository {
  final List<int> groupSizes = [];

  @override
  Future<void> appendOperationGroup(List<SyncOperation> operations) async {
    groupSizes.add(operations.length);
    await super.appendOperationGroup(operations);
  }
}

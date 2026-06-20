import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

void main() {
  test('resolver matches sync engine conflict resolution', () async {
    final repo = InMemorySyncRepository();
    final engine = SyncEngine(syncRepository: repo, deviceId: 'device-a');
    final resolver = CrdtDocumentResolver();
    final now = utcNow();
    final task = TodoTask(
      id: 'task-1',
      listId: 'list-1',
      title: 'Merged title',
      createdAt: now,
      updatedAt: now,
    );

    await repo.appendOperation(
      SyncOperation(
        id: 'op-1',
        documentId: 'task-1',
        sequence: 1,
        payload: jsonEncode(todoTaskToFirestore(task.copyWith(title: 'First'))),
        deviceId: 'device-a',
        timestamp: now,
      ),
    );
    await repo.appendOperation(
      SyncOperation(
        id: 'op-2',
        documentId: 'task-1',
        sequence: 2,
        payload: jsonEncode(todoTaskToFirestore(task)),
        deviceId: 'device-b',
        timestamp: now.add(const Duration(seconds: 1)),
      ),
    );

    final resolvedJson = await engine.resolveConflicts('task-1');
    final resolvedPayload = await resolver.resolvePayload(repo, 'task-1');

    expect(resolvedJson, jsonEncode(resolvedPayload));
    expect(resolvedPayload?['title'], 'Merged title');

    engine.dispose();
  });
}

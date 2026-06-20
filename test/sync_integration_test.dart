import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  test('calendar lock prevents concurrent google sync claims', () async {
    final repo = InMemorySyncRepository();
    final now = DateTime.now().toUtc();
    final lockA = GoogleCalendarSyncLock(
      deviceId: 'device-a',
      lockedAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    final lockB = GoogleCalendarSyncLock(
      deviceId: 'device-b',
      lockedAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
    );

    expect(await repo.claimCalendarLock(lockA), isTrue);
    expect(await repo.claimCalendarLock(lockB), isFalse);
    await repo.releaseCalendarLock('device-a');
    expect(await repo.claimCalendarLock(lockB), isTrue);
  });

  test('todo document watcher receives live updates', () async {
    final repo = InMemorySyncRepository();
    final events = <Map<String, dynamic>>[];
    final sub = repo.watchDocument('todo_tasks', 'task-1').listen(events.add);

    await repo.upsertDocument('todo_tasks', 'task-1', {'completed': false});
    await repo.upsertDocument('todo_tasks', 'task-1', {'completed': true});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(events, hasLength(2));
    expect(events.last['completed'], isTrue);
    await sub.cancel();
  });

  test(
    'sync engine retries debounced document uploads and records operation',
    () async {
      final repo = _FlakySyncRepository(failuresBeforeSuccess: 1);
      final engine = SyncEngine(
        syncRepository: repo,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
        retryPolicy: const SyncRetryPolicy(
          initialBackoff: Duration(milliseconds: 1),
        ),
      );

      engine.scheduleDocumentSync(
        collection: 'journal_entries',
        documentId: 'entry-1',
        payload: {'title': 'Recovered'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final operations = await repo.listOperations('entry-1');
      expect(repo.upsertAttempts, 2);
      expect(operations, hasLength(1));
      expect(operations.single.sequence, 1);
      expect(operations.single.payload, '{"title":"Recovered"}');

      engine.dispose();
    },
  );

  test('startup pull purges expired deletes before local refresh', () async {
    final repo = InMemorySyncRepository();
    final engine = SyncEngine(
      syncRepository: repo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: Duration.zero),
    );
    final calls = <String>[];

    await engine.pullOnStartup(
      purgeExpiredDeleted: () async => calls.add('purge'),
      localRefresh: () async => calls.add('refresh'),
    );

    expect(calls, ['purge', 'refresh']);
    engine.dispose();
  });
}

class _FlakySyncRepository extends InMemorySyncRepository {
  _FlakySyncRepository({required this.failuresBeforeSuccess});

  final int failuresBeforeSuccess;
  int upsertAttempts = 0;

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    upsertAttempts++;
    if (upsertAttempts <= failuresBeforeSuccess) {
      throw StateError('temporary outage');
    }
    await super.upsertDocument(collection, id, data);
  }
}

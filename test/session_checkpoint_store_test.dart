// A checkpoint is the only record an unfinished session leaves, so the store
// has to be exactly as reliable as the scratch file it replaces: a faithful
// round trip, one slot per kind and scope, and a blob it cannot read treated
// as no session rather than as an error.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/session_resume/session_checkpoint.dart';
import 'package:voyager/core/session_resume/session_checkpoint_controller.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';

SessionCheckpoint _checkpoint({
  SessionCheckpointKind kind = SessionCheckpointKind.studySession,
  String scopeKey = 'hub',
  List<String> remainingQueue = const ['c1', 'c2'],
  List<GradeStepDto> graded = const [],
  CramBucketsDto? buckets,
  Map<String, dynamic>? scratch,
}) => SessionCheckpoint(
  kind: kind,
  scopeKey: scopeKey,
  sessionId: 's1',
  startedAt: DateTime.utc(2026, 9, 19, 9),
  updatedAt: DateTime.utc(2026, 9, 19, 10),
  sourceIds: const {'c1', 'c2', 'c3'},
  remainingQueue: remainingQueue,
  buckets: buckets,
  graded: graded,
  scratch: scratch,
);

GradeStepDto _step() => GradeStepDto(
  before: {'id': 'c3', 'interval': 0.0},
  after: {'id': 'c3', 'interval': 1.0},
  log: {'id': 'log-1', 'cardId': 'c3'},
  queueBefore: const ['c3', 'c1', 'c2'],
  queueAfter: const ['c1', 'c2'],
);

void main() {
  late Directory dir;
  late FileSessionCheckpointStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('voyager_checkpoint_test');
    store = FileSessionCheckpointStore(directory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File file(String name) => File('${dir.path}/session_checkpoints/$name.json');

  group('round trip', () {
    test('a saved study session loads back with every field intact', () async {
      await store.save(
        _checkpoint(
          graded: [_step()],
          scratch: {
            'lastLanguage': 'python',
            'scratches': {
              'c1': {'code': 'typed', 'language': 'python', 'expanded': true},
            },
          },
        ),
      );

      final loaded = await store.load(
        SessionCheckpointKind.studySession,
        'hub',
      );
      expect(loaded, isNotNull);
      expect(loaded!.sessionId, 's1');
      expect(loaded.startedAt, DateTime.utc(2026, 9, 19, 9));
      expect(loaded.updatedAt, DateTime.utc(2026, 9, 19, 10));
      expect(loaded.sourceIds, {'c1', 'c2', 'c3'});
      expect(loaded.remainingQueue, ['c1', 'c2']);
      expect(loaded.graded.single.id, 'c3');
      expect(loaded.graded.single.before['interval'], 0.0);
      expect(loaded.graded.single.queueBefore, ['c3', 'c1', 'c2']);
      expect(loaded.scratch!['lastLanguage'], 'python');
    });

    test('a saved cram run keeps its buckets and decisions', () async {
      await store.save(
        _checkpoint(
          kind: SessionCheckpointKind.studyCram,
          scopeKey: 'deck:d1',
          remainingQueue: const [],
          buckets: const CramBucketsDto(
            bucket0: ['c1'],
            bucket1: ['c2'],
            bucket2: ['c3'],
          ),
        ),
      );

      final loaded = await store.load(
        SessionCheckpointKind.studyCram,
        'deck:d1',
      );
      expect(loaded!.buckets!.bucket0, ['c1']);
      expect(loaded.buckets!.bucket1, ['c2']);
      expect(loaded.buckets!.bucket2, ['c3']);
    });

    test('no file means no checkpoint', () async {
      expect(await store.load(SessionCheckpointKind.leetcodeStudy, ''), isNull);
    });
  });

  group('one slot per kind and scope', () {
    test('Study and Cram never read each other', () async {
      await store.save(
        _checkpoint(kind: SessionCheckpointKind.leetcodeStudy, scopeKey: ''),
      );

      expect(await store.load(SessionCheckpointKind.leetcodeCram, ''), isNull);
      expect(
        await store.load(SessionCheckpointKind.leetcodeStudy, ''),
        isNotNull,
      );
    });

    test('the Hub and a deck never read each other', () async {
      await store.save(_checkpoint(scopeKey: 'hub'));
      await store.save(
        _checkpoint(scopeKey: 'deck:d1', remainingQueue: const ['c9']),
      );

      final hub = await store.load(SessionCheckpointKind.studySession, 'hub');
      final deck = await store.load(
        SessionCheckpointKind.studySession,
        'deck:d1',
      );
      expect(hub!.remainingQueue, ['c1', 'c2']);
      expect(deck!.remainingQueue, ['c9']);
    });

    test('clearing one leaves the other alone', () async {
      await store.save(_checkpoint(scopeKey: 'hub'));
      await store.save(_checkpoint(scopeKey: 'deck:d1'));

      await store.clear(SessionCheckpointKind.studySession, 'hub');

      expect(
        await store.load(SessionCheckpointKind.studySession, 'hub'),
        isNull,
      );
      expect(
        await store.load(SessionCheckpointKind.studySession, 'deck:d1'),
        isNotNull,
      );
    });
  });

  group('unreadable files', () {
    test('corrupt JSON is discarded, not thrown', () async {
      await store.save(_checkpoint());
      await file('studySession__hub').writeAsString('{not json');

      expect(
        await store.load(SessionCheckpointKind.studySession, 'hub'),
        isNull,
      );
      // Discarded rather than left to fail the same way on every open.
      expect(await file('studySession__hub').exists(), isFalse);
    });

    test('a file from another version is discarded', () async {
      await store.save(_checkpoint());
      await file(
        'studySession__hub',
      ).writeAsString(jsonEncode({'version': 99, 'kind': 'studySession'}));

      expect(
        await store.load(SessionCheckpointKind.studySession, 'hub'),
        isNull,
      );
    });

    test('an empty file is no checkpoint', () async {
      await store.save(_checkpoint());
      await file('studySession__hub').writeAsString('   ');

      expect(
        await store.load(SessionCheckpointKind.studySession, 'hub'),
        isNull,
      );
    });
  });

  test('clearing when there is no file is not an error', () async {
    await store.clear(SessionCheckpointKind.studyCram, 'deck:gone');
    expect(
      await store.load(SessionCheckpointKind.studyCram, 'deck:gone'),
      isNull,
    );
  });

  test('writes are chained, so the last one wins', () async {
    // A dispose flush landing on top of a still-pending debounce is exactly
    // the race the chain exists for: both are fired without awaiting, and the
    // file must end up holding the second.
    final first = store.save(_checkpoint(remainingQueue: const ['a']));
    final second = store.save(_checkpoint(remainingQueue: const ['b']));
    await Future.wait([first, second]);

    final loaded = await store.load(SessionCheckpointKind.studySession, 'hub');
    expect(loaded!.remainingQueue, ['b']);
  });

  group('the app going to the background', () {
    // Pausing is an incomplete exit that never reaches dispose, and on a
    // phone the process can be killed from there. Whatever the debounce is
    // still holding has to reach disk on the way out.
    SessionCheckpointController controllerFor(
      MemorySessionCheckpointStore store,
      SessionCheckpoint? Function() build,
    ) => SessionCheckpointController(
      store: store,
      kind: SessionCheckpointKind.studySession,
      scopeKey: 'hub',
      build: build,
    );

    test('writes what the debounce was still holding', () async {
      final memory = MemorySessionCheckpointStore();
      final controller = controllerFor(
        memory,
        () => _checkpoint(remainingQueue: const ['paused']),
      );
      addTearDown(controller.dispose);

      controller.persist();
      // Nothing has reached the slot yet: the debounce is still running.
      expect(memory.checkpoints, isEmpty);

      await PendingFlushRegistry.instance.flushAll();
      expect(memory.checkpoints['studySession__hub']!.remainingQueue, [
        'paused',
      ]);
    });

    test('a disposed session is no longer flushed', () async {
      final memory = MemorySessionCheckpointStore();
      var builds = 0;
      final controller = controllerFor(memory, () {
        builds++;
        return _checkpoint();
      });

      controller.dispose();
      await PendingFlushRegistry.instance.flushAll();

      // Unregistering relies on the tear-off being the same callback the
      // constructor handed over; if it were not, the registry would go on
      // holding a session that has already gone.
      expect(builds, 0);
      expect(memory.checkpoints, isEmpty);
    });
  });

  test('the memory store is the same contract', () async {
    final memory = MemorySessionCheckpointStore();
    expect(
      await memory.load(SessionCheckpointKind.studySession, 'hub'),
      isNull,
    );

    await memory.save(_checkpoint());
    expect(
      (await memory.load(SessionCheckpointKind.studySession, 'hub'))!.sessionId,
      's1',
    );
    expect(await memory.load(SessionCheckpointKind.studyCram, 'hub'), isNull);

    await memory.clear(SessionCheckpointKind.studySession, 'hub');
    expect(
      await memory.load(SessionCheckpointKind.studySession, 'hub'),
      isNull,
    );
  });
}

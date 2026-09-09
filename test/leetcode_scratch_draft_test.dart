// The scratch session file is the only thing that survives a Study or Cram run
// dying mid-session. These pin the round trip, what a corrupt blob does, and
// the one rule the whole crash-recovery story rests on: a session that ended
// cleanly leaves nothing behind to offer back.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft_store.dart';

LeetCodeScratchSession _session({
  Map<String, LeetCodeScratchEntry> scratches = const {},
  bool endedNormally = false,
  String? lastLanguage,
}) => LeetCodeScratchSession(
  sessionId: 's1',
  problemIds: const {'p1', 'p2'},
  startedAt: DateTime.utc(2026, 8, 31, 16),
  endedNormally: endedNormally,
  lastLanguage: lastLanguage,
  scratches: scratches,
);

void main() {
  late Directory dir;
  late FileLeetCodeScratchDraftStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('voyager_scratch_test');
    store = FileLeetCodeScratchDraftStore(directory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File file() => File('${dir.path}/leetcode_scratch_session.json');

  group('round trip', () {
    test('a saved session loads back with every field intact', () async {
      await store.save(
        _session(
          lastLanguage: 'java',
          scratches: {
            'p1': const LeetCodeScratchEntry(
              code: 'class Solution {\n}',
              language: 'java',
              expanded: true,
            ),
          },
        ),
      );

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.sessionId, 's1');
      expect(loaded.problemIds, {'p1', 'p2'});
      expect(loaded.startedAt, DateTime.utc(2026, 8, 31, 16));
      expect(loaded.lastLanguage, 'java');
      expect(loaded.scratches['p1']!.code, 'class Solution {\n}');
      expect(loaded.scratches['p1']!.language, 'java');
      expect(loaded.scratches['p1']!.expanded, isTrue);
    });

    test('no file means no session', () async {
      expect(await store.load(), isNull);
    });
  });

  group('unreadable blobs', () {
    test('corrupt JSON is discarded, not thrown', () async {
      await file().writeAsString('{not json');
      expect(await store.load(), isNull);
      // Discarded rather than left to fail the same way on every open.
      expect(await file().exists(), isFalse);
    });

    test('a blob from another version is discarded', () async {
      await file().writeAsString(jsonEncode({'version': 99, 'sessionId': 'x'}));
      expect(await store.load(), isNull);
    });

    test('an empty file is no session', () async {
      await file().writeAsString('   ');
      expect(await store.load(), isNull);
    });
  });

  group('clear', () {
    test('removes the file, so nothing is offered back', () async {
      await store.save(_session());
      expect(await file().exists(), isTrue);
      await store.clear();
      expect(await file().exists(), isFalse);
      expect(await store.load(), isNull);
    });

    test('clearing when there is no file is not an error', () async {
      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  test('writes are chained, so the last one wins', () async {
    // A dispose flush landing on top of a still-pending debounce is exactly
    // the race the chain exists for: both are fired without awaiting, and the
    // file must end up holding the second.
    final first = store.save(
      _session(
        scratches: {'p1': const LeetCodeScratchEntry(code: 'a', language: 'python')},
      ),
    );
    final second = store.save(
      _session(
        scratches: {'p1': const LeetCodeScratchEntry(code: 'b', language: 'python')},
      ),
    );
    await Future.wait([first, second]);

    expect((await store.load())!.scratches['p1']!.code, 'b');
  });

  group('orphan detection', () {
    test('a live session holding text is an orphan', () {
      final session = _session(
        scratches: {
          'p1': const LeetCodeScratchEntry(code: 'work', language: 'python'),
        },
      );
      expect(session.isOrphan, isTrue);
    });

    test('a session that ended normally is never offered back', () {
      final session = _session(
        endedNormally: true,
        scratches: {
          'p1': const LeetCodeScratchEntry(code: 'work', language: 'python'),
        },
      );
      expect(session.isOrphan, isFalse);
    });

    test('an untouched pad is nothing to recover', () {
      expect(_session().isOrphan, isFalse);
      expect(
        _session(
          scratches: {
            'p1': const LeetCodeScratchEntry(code: '   \n\n', language: 'python'),
          },
        ).isOrphan,
        isFalse,
      );
    });

    test('a starter template the user never touched still counts as text', () {
      // The recovery offer cannot tell a starter from typing, and offering one
      // back costs the user a single Discard — losing real work does not.
      expect(
        _session(
          scratches: {
            'p1': const LeetCodeScratchEntry(
              code: 'class Solution:\n    pass',
              language: 'python',
            ),
          },
        ).isOrphan,
        isTrue,
      );
    });
  });

  test('the memory store is the same contract', () async {
    final memory = MemoryLeetCodeScratchDraftStore();
    expect(await memory.load(), isNull);
    await memory.save(_session(lastLanguage: 'go'));
    expect((await memory.load())!.lastLanguage, 'go');
    await memory.clear();
    expect(await memory.load(), isNull);
  });
}

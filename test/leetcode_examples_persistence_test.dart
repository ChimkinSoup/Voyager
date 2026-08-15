// Examples are the one LeetCode field that is a list, so it has two places to
// silently lose the user's text: the JSON column it round-trips through, and
// the remote merge, which has to tell "the other device cleared the list"
// apart from "the other device is on a build that never wrote the key".

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

LeetCodeProblem _problem({
  List<String> examples = const [],
  int version = 0,
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.utc(2026, 8, 12, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: DateTime.utc(2026, 8, 12, 9),
    updatedAt: now,
    version: version,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    examples: examples,
    solvedAt: now,
  );
}

void main() {
  group('drift round-trip', () {
    late AppDatabase db;
    late DriftLeetCodeRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftLeetCodeRepository(db);
    });

    tearDown(() async => db.close());

    test('keeps examples and their order', () async {
      await repo.upsertProblem(
        _problem(examples: ['Input: [2,7]\nOutput: [0,1]', 'Input: [3,3]']),
      );
      final stored = (await repo.listProblems()).single;
      expect(stored.examples, ['Input: [2,7]\nOutput: [0,1]', 'Input: [3,3]']);
    });

    test(
      'a problem saved with no examples reads back empty, not null',
      () async {
        await repo.upsertProblem(_problem());
        expect((await repo.listProblems()).single.examples, isEmpty);
      },
    );

    test('removing every example persists as removed', () async {
      await repo.upsertProblem(_problem(examples: const ['Input: [2,7]']));
      await repo.upsertProblem(_problem(examples: const [], version: 1));
      expect((await repo.listProblems()).single.examples, isEmpty);
    });
  });

  group('firestore merge', () {
    // Newer than the local record below, so the remote copy wins the merge and
    // the field-level fallbacks are what's actually under test.
    final remoteUpdated = DateTime.utc(2026, 8, 12, 18);

    test('takes the remote list when the key is present', () {
      final merged = mergeLeetCodeProblemFromRemote(
        {
          'title': 'Two Sum',
          'examples': ['Input: [3,3]'],
          'updatedAt': remoteUpdated.toIso8601String(),
          'version': 2,
        },
        'p1',
        local: _problem(examples: const ['Input: [2,7]']),
      );
      expect(merged.examples, ['Input: [3,3]']);
    });

    test('an explicitly empty remote list clears the local one', () {
      final merged = mergeLeetCodeProblemFromRemote(
        {
          'title': 'Two Sum',
          'examples': <String>[],
          'updatedAt': remoteUpdated.toIso8601String(),
          'version': 2,
        },
        'p1',
        local: _problem(examples: const ['Input: [2,7]']),
      );
      expect(merged.examples, isEmpty);
    });

    test(
      'a document written before the field existed keeps local examples',
      () {
        final merged = mergeLeetCodeProblemFromRemote(
          {
            'title': 'Two Sum',
            'updatedAt': remoteUpdated.toIso8601String(),
            'version': 2,
          },
          'p1',
          local: _problem(examples: const ['Input: [2,7]']),
        );
        expect(merged.examples, ['Input: [2,7]']);
      },
    );

    test('survives a push/merge round-trip', () {
      final problem = _problem(
        examples: const ['Input: [2,7]', 'Input: [3,3]'],
      );
      final merged = mergeLeetCodeProblemFromRemote(
        leetCodeProblemToFirestore(problem),
        problem.id,
      );
      expect(merged.examples, problem.examples);
    });
  });

  group('json round-trip', () {
    test('export/import keeps examples', () {
      final problem = _problem(examples: const ['Input: [2,7]']);
      expect(
        LeetCodeProblem.fromJson(problem.toJson()).examples,
        problem.examples,
      );
    });

    test('a record exported before the field existed imports as empty', () {
      final json = _problem().toJson()..remove('examples');
      expect(LeetCodeProblem.fromJson(json).examples, isEmpty);
    });
  });
}

// A problem's write-up used to be a single set of flat fields and is now a
// list of them. Everything that stores or ships one has to survive that: the
// JSON column it round-trips through, the export file, the remote merge — and
// the upgrade itself, which has to find the old single solution rather than
// leave the user looking at a blank card.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

const _bruteForce = LeetCodeSolution(
  algorithm: 'Compare every pair',
  timeComplexity: 'O(n^2)',
  spaceComplexity: 'O(1)',
  explanation: 'Two nested loops over the array',
  code: 'def two_sum(nums, t): pass',
  notes: 'the one to open with',
);

const _hashMap = LeetCodeSolution(
  algorithm: 'Hash map of complements',
  timeComplexity: 'O(n)',
  spaceComplexity: 'O(n)',
  explanation: 'Look up t - nums[i] as you go',
  codeLanguage: 'cpp',
  code: 'int* twoSum(int* nums) {}',
);

LeetCodeProblem _problem({
  List<LeetCodeSolution> solutions = const [],
  int version = 0,
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.utc(2026, 8, 14, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: DateTime.utc(2026, 8, 14, 9),
    updatedAt: now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    version: version,
    solutions: solutions,
    solvedAt: now,
  );
}

void main() {
  group('the model', () {
    test(
      'a problem follows its first solution for inline-code highlighting',
      () {
        expect(_problem(solutions: const [_hashMap]).codeLanguage, 'cpp');
      },
    );

    test('a problem with nothing written down falls back to python', () {
      expect(_problem().codeLanguage, 'python');
    });

    test('a solution with every box blank knows it is empty', () {
      expect(const LeetCodeSolution().isEmpty, isTrue);
      expect(const LeetCodeSolution(algorithm: '  ').isEmpty, isTrue);
      // Whitespace in the code box is still nothing written down.
      expect(const LeetCodeSolution(code: '\n').isEmpty, isTrue);
      expect(const LeetCodeSolution(notes: 'x').isEmpty, isFalse);
    });
  });

  group('drift round-trip', () {
    late AppDatabase db;
    late DriftLeetCodeRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftLeetCodeRepository(db);
    });

    tearDown(() async => db.close());

    test('keeps every solution, its language and its order', () async {
      await repo.upsertProblem(
        _problem(solutions: const [_bruteForce, _hashMap]),
      );
      final stored = (await repo.listProblems()).single;
      expect(stored.solutions.length, 2);
      expect(stored.solutions.first.algorithm, 'Compare every pair');
      expect(stored.solutions.first.notes, 'the one to open with');
      expect(stored.solutions.last.algorithm, 'Hash map of complements');
      expect(stored.solutions.last.codeLanguage, 'cpp');
      expect(stored.solutions.last.notes, isNull);
    });

    test(
      'a problem saved with no solutions reads back empty, not null',
      () async {
        await repo.upsertProblem(_problem());
        expect((await repo.listProblems()).single.solutions, isEmpty);
      },
    );

    test('removing the alternatives persists as removed', () async {
      await repo.upsertProblem(
        _problem(solutions: const [_bruteForce, _hashMap]),
      );
      await repo.upsertProblem(
        _problem(solutions: const [_hashMap], version: 1),
      );
      final stored = (await repo.listProblems()).single;
      expect(stored.solutions.single.algorithm, 'Hash map of complements');
    });
  });

  group('76→77 migration', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_lc_solutions_test');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// Rewinds to a schema-76 database: drops the solutions column and resets
    /// user_version, so reopening runs the real onUpgrade path. The flat
    /// columns are left as they are — writes keep them in step with solution
    /// 1, which is exactly the state a schema-76 row was in.
    Future<void> rewindToSchema76() async {
      final db = AppDatabase(NativeDatabase(file));
      await db.customStatement(
        'ALTER TABLE leet_code_problems_table DROP COLUMN solutions_json',
      );
      await db.customStatement('PRAGMA user_version = 76');
      await db.close();
    }

    test('folds the single flat solution into the list', () async {
      final seed = AppDatabase(NativeDatabase(file));
      await DriftLeetCodeRepository(
        seed,
      ).upsertProblem(_problem(solutions: const [_bruteForce]));
      await seed.close();

      await rewindToSchema76();

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final problem = (await DriftLeetCodeRepository(
        upgraded,
      ).listProblems()).single;

      expect(problem.solutions.length, 1);
      expect(problem.solutions.single.algorithm, 'Compare every pair');
      expect(problem.solutions.single.timeComplexity, 'O(n^2)');
      expect(problem.solutions.single.explanation, isNotEmpty);
      expect(problem.solutions.single.code, 'def two_sum(nums, t): pass');
      expect(problem.solutions.single.notes, 'the one to open with');
    });

    test('a problem with nothing written down gains no solution', () async {
      final seed = AppDatabase(NativeDatabase(file));
      await DriftLeetCodeRepository(seed).upsertProblem(_problem());
      await seed.close();

      await rewindToSchema76();

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final problem = (await DriftLeetCodeRepository(
        upgraded,
      ).listProblems()).single;

      expect(problem.solutions, isEmpty);
    });
  });

  group('firestore merge', () {
    // Newer than the local record below, so the remote copy wins the merge and
    // the field-level fallbacks are what's actually under test.
    final remoteUpdated = DateTime.utc(2026, 8, 14, 18);

    Map<String, dynamic> remote(Map<String, dynamic> extra) => {
      'title': 'Two Sum',
      'updatedAt': remoteUpdated.toIso8601String(),
      'version': 2,
      ...extra,
    };

    test('takes the remote list when the key is present', () {
      final merged = mergeLeetCodeProblemFromRemote(
        remote({
          'solutions': [_bruteForce.toJson(), _hashMap.toJson()],
        }),
        'p1',
        local: _problem(solutions: const [_hashMap]),
      );
      expect(merged.solutions.length, 2);
      expect(merged.solutions.first.algorithm, 'Compare every pair');
    });

    test('an explicitly empty remote list clears the local one', () {
      final merged = mergeLeetCodeProblemFromRemote(
        remote({'solutions': <Map<String, dynamic>>[]}),
        'p1',
        local: _problem(solutions: const [_hashMap]),
      );
      expect(merged.solutions, isEmpty);
    });

    test('a device on the old build still lands its edit', () {
      // No `solutions` key, only the flat fields it knows how to write — that
      // is a real edit from that device, not a document missing a field.
      final merged = mergeLeetCodeProblemFromRemote(
        remote({
          'algorithm': 'Sliding window',
          'timeComplexity': 'O(n)',
          'explanation': 'Grow and shrink the window',
          'codeLanguage': 'go',
          'code': 'func solve() {}',
          'notes': null,
        }),
        'p1',
        local: _problem(solutions: const [_bruteForce, _hashMap]),
      );
      expect(merged.solutions.length, 1);
      expect(merged.solutions.single.algorithm, 'Sliding window');
      expect(merged.solutions.single.codeLanguage, 'go');
    });

    test('a document written before either field existed keeps local ones', () {
      final merged = mergeLeetCodeProblemFromRemote(
        remote(const {}),
        'p1',
        local: _problem(solutions: const [_bruteForce, _hashMap]),
      );
      expect(merged.solutions.length, 2);
    });

    test('survives a push/merge round-trip', () {
      final problem = _problem(solutions: const [_bruteForce, _hashMap]);
      final merged = mergeLeetCodeProblemFromRemote(
        leetCodeProblemToFirestore(problem),
        problem.id,
      );
      expect(merged.solutions.length, 2);
      expect(merged.solutions.last.code, _hashMap.code);
    });

    test('the pushed document still shows solution 1 to an old build', () {
      final data = leetCodeProblemToFirestore(
        _problem(solutions: const [_bruteForce, _hashMap]),
      );
      expect(data['algorithm'], _bruteForce.algorithm);
      expect(data['code'], _bruteForce.code);
      expect(data['notes'], _bruteForce.notes);
    });
  });

  group('json round-trip', () {
    test('export/import keeps every solution', () {
      final problem = _problem(solutions: const [_bruteForce, _hashMap]);
      final imported = LeetCodeProblem.fromJson(problem.toJson());
      expect(imported.solutions.length, 2);
      expect(imported.solutions.last.codeLanguage, 'cpp');
    });

    test(
      'a record exported before the list existed imports as one solution',
      () {
        final json = _problem(solutions: const [_bruteForce]).toJson()
          ..remove('solutions');
        final imported = LeetCodeProblem.fromJson(json);
        expect(imported.solutions.single.algorithm, 'Compare every pair');
      },
    );

    test('a record with no write-up at all imports as none', () {
      final json = _problem().toJson()..remove('solutions');
      expect(LeetCodeProblem.fromJson(json).solutions, isEmpty);
    });
  });
}

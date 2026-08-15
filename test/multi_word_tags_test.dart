// A tag is one whitespace-delimited token, which used to mean LeetCode's
// prose-named topics ("Hash Table") arrived as a tag per word. The hyphen is
// what joins them back into one, so these cover both halves of that: the
// grammar that now reads a hyphenated name as a single tag, and the Track
// modal turning the API's names into that form on the way in.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

class _RecordingLeetCodeRepository implements LeetCodeRepository {
  final saved = <LeetCodeProblem>[];

  @override
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  }) async => saved.add(problem);

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => const [];

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Opens the Track modal on [prefill] — the state the automatic pull leaves the
/// form in, the user's latest accepted submission having already been fetched.
Future<_RecordingLeetCodeRepository> _openModal(
  WidgetTester tester, {
  LeetCodeApiQuestion? prefill,
  LeetCodeProblem? existing,
}) async {
  final repo = _RecordingLeetCodeRepository();
  // Tall enough that the form needs no scrolling, so nothing parks under the
  // pinned close button — same reason the other track-modal tests do it.
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // The tags field's completion pool reaches for databaseProvider, which
  // otherwise opens the real on-disk voyager.sqlite.
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        leetCodeRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showLeetCodeTrackModal(
                context,
                ref,
                prefill: prefill,
                existing: existing,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _save(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

LeetCodeProblem _problem({required List<String> tags}) {
  final now = DateTime.utc(2026, 8, 15, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    tags: tags,
    solvedAt: now,
  );
}

void main() {
  group('leetCodeTagToken', () {
    test('joins a multi-word topic name into one token', () {
      expect(leetCodeTagToken('Hash Table'), 'Hash-Table');
      expect(
        leetCodeTagToken('Probability and Statistics'),
        'Probability-and-Statistics',
      );
    });

    test('leaves a topic that is already one word alone', () {
      expect(leetCodeTagToken('Array'), 'Array');
      // LeetCode hyphenates some of its own names; they need no rewriting.
      expect(leetCodeTagToken('Depth-First Search'), 'Depth-First-Search');
    });

    test('keeps the API casing, which is what colors the tag', () {
      expect(leetCodeTagToken('Bit Manipulation'), 'Bit-Manipulation');
      expect(
        colorForTag(leetCodeTagToken('Bit Manipulation')),
        isNot(colorForTag('bit-manipulation')),
      );
    });
  });

  group('journalTagPattern', () {
    test('reads a hyphenated name as a single tag', () {
      expect(extractTags('solved #Hash-Table today'), ['Hash-Table']);
      expect(extractTags('#Depth-First-Search'), ['Depth-First-Search']);
    });

    test('stops at a trailing hyphen, which is punctuation', () {
      expect(extractTags('#done- and then'), ['done']);
      expect(extractTags('#a--b'), ['a']);
    });

    test('still reads plain tags the way it always did', () {
      expect(extractTags('#array #greedy'), ['array', 'greedy']);
      expect(extractTags('C# is not a tag'), isEmpty);
    });
  });

  group('activeTagToken', () {
    test('spans the whole hyphenated tag the caret sits in', () {
      final token = activeTagToken('#Hash-Table', 11);
      expect(token, isNotNull);
      expect(token!.start, 0);
      expect(token.end, 11);
      expect(token.query, 'Hash-Table');
    });

    test('holds the tag together across a hyphen just typed', () {
      // The one character where the token is wider than what the highlighter
      // paints — and the moment completion is most useful.
      final token = activeTagToken('#Hash-', 6);
      expect(token?.query, 'Hash-');
      expect(filterTagSuggestions(const ['Hash-Table', 'Array'], 'Hash-'), [
        'Hash-Table',
      ]);
    });

    test('a hyphen before the # belongs to the prose, not to the tag', () {
      expect(activeTagToken('well-#known', 11), isNotNull);
    });
  });

  group('the Track modal', () {
    testWidgets('files a multi-word topic from the automatic pull as one tag', (
      tester,
    ) async {
      final repo = await _openModal(
        tester,
        prefill: const LeetCodeApiQuestion(
          questionId: '1',
          questionFrontendId: '1',
          title: 'Two Sum',
          titleSlug: 'two-sum',
          difficulty: LeetCodeDifficulty.easy,
          topicTags: ['Array', 'Hash Table'],
        ),
      );

      await _save(tester, 'Save');

      expect(repo.saved.single.tags, ['Array', 'Hash-Table']);
    });

    testWidgets('leaves an already-saved tag exactly as it was', (
      tester,
    ) async {
      // Saved tags are tokens already — they must not be re-tokenized on the
      // way back into the field, or an edit would rewrite tags it never touched.
      final repo = await _openModal(
        tester,
        existing: _problem(tags: const ['Hash-Table', 'stale-tag']),
      );

      await _save(tester, 'Save changes');

      expect(repo.saved.single.tags, ['Hash-Table', 'stale-tag']);
    });
  });
}

// Where the solutions surface, and how they're titled once there's more than
// one. The rule is the same on every face: a lone solution carries no heading,
// because there is nothing to tell it apart from.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';
import 'package:voyager/features/study/study_flip_card.dart';

const _bruteForce = LeetCodeSolution(
  algorithm: 'Compare every pair',
  timeComplexity: 'O(n^2)',
  spaceComplexity: 'O(1)',
  explanation: 'Two nested loops over the array',
  code: 'def brute(nums): pass',
  notes: 'never say this one first',
);

const _hashMap = LeetCodeSolution(
  algorithm: 'Hash map of complements',
  timeComplexity: 'O(n)',
  spaceComplexity: 'O(n)',
  explanation: 'Look up t - nums[i] as you go',
  code: 'def hashed(nums): pass',
);

LeetCodeProblem _problem({List<LeetCodeSolution> solutions = const []}) {
  final now = DateTime.utc(2026, 8, 14, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    questionFrontendId: '1',
    difficulty: LeetCodeDifficulty.easy,
    solutions: solutions,
    solvedAt: now,
  );
}

/// Pumps the full-size card and turns it over.
Future<void> _pumpCardBack(WidgetTester tester, LeetCodeProblem problem) async {
  final flip = StudyFlipController();
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 700,
              height: 1200,
              child: LeetCodeFlashcard(problem: problem, controller: flip),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  flip.flip();
  await tester.pumpAndSettle();
}

Future<void> _pumpTileBack(WidgetTester tester, LeetCodeProblem problem) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              height: 220,
              child: LeetCodeMiniFlashcard(
                problem: problem,
                showBack: true,
                onFlipped: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the flashcard back', () {
    testWidgets('shows a lone solution with no heading', (tester) async {
      await _pumpCardBack(tester, _problem(solutions: const [_hashMap]));

      expect(find.text('Hash map of complements'), findsOneWidget);
      expect(find.text('Solution 1'), findsNothing);
      // One set of section labels, not one per solution.
      expect(find.text('Algorithm'), findsOneWidget);
      expect(find.text('Explanation'), findsOneWidget);
    });

    testWidgets('shows every solution once there is more than one', (
      tester,
    ) async {
      await _pumpCardBack(
        tester,
        _problem(solutions: const [_bruteForce, _hashMap]),
      );

      expect(find.text('Solution 1'), findsOneWidget);
      expect(find.text('Solution 2'), findsOneWidget);
      expect(find.text('Compare every pair'), findsOneWidget);
      expect(find.text('Hash map of complements'), findsOneWidget);
      expect(find.text('Two nested loops over the array'), findsOneWidget);
      expect(find.text('Look up t - nums[i] as you go'), findsOneWidget);
      expect(find.text('Algorithm'), findsNWidgets(2));
      expect(find.text('Time: O(n^2)'), findsOneWidget);
      expect(find.text('Time: O(n)'), findsOneWidget);
    });

    testWidgets('leaves notes to the detail view', (tester) async {
      await _pumpCardBack(tester, _problem(solutions: const [_bruteForce]));

      expect(find.text('never say this one first'), findsNothing);
      expect(find.text('Notes'), findsNothing);
    });
  });

  group('the mini tile back', () {
    testWidgets('previews the first solution and counts the rest', (
      tester,
    ) async {
      await _pumpTileBack(
        tester,
        _problem(solutions: const [_bruteForce, _hashMap]),
      );

      expect(find.text('Compare every pair'), findsOneWidget);
      expect(find.text('+1 more'), findsOneWidget);
      // At this size a second write-up would be a few illegible words, so the
      // count is all the tile says about it.
      expect(find.text('Hash map of complements'), findsNothing);
    });

    testWidgets('says nothing about alternatives when there are none', (
      tester,
    ) async {
      await _pumpTileBack(tester, _problem(solutions: const [_bruteForce]));

      expect(find.textContaining('more'), findsNothing);
      expect(find.text('T O(n^2)  ·  S O(1)'), findsOneWidget);
    });

    testWidgets('a problem with no write-up still says so', (tester) async {
      await _pumpTileBack(tester, _problem());

      expect(find.text('No approach written'), findsOneWidget);
      expect(find.textContaining('more'), findsNothing);
    });
  });

  group('the detail view', () {
    Future<void> open(WidgetTester tester, LeetCodeProblem problem) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openLeetCodeDetailView(
                    context,
                    problem,
                    const Rect.fromLTWH(0, 0, 100, 100),
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
    }

    testWidgets('shows the notes the flashcard back leaves out', (
      tester,
    ) async {
      await open(tester, _problem(solutions: const [_bruteForce]));

      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('never say this one first'), findsOneWidget);
      expect(find.text('Solution 1'), findsNothing);
    });

    testWidgets('titles the solutions once there is more than one', (
      tester,
    ) async {
      await open(tester, _problem(solutions: const [_bruteForce, _hashMap]));

      expect(find.text('Solution 1'), findsOneWidget);
      expect(find.text('Solution 2'), findsOneWidget);
      expect(find.text('Compare every pair'), findsOneWidget);
      expect(find.text('Hash map of complements'), findsOneWidget);
      // Only the solution that has notes shows a Notes block.
      expect(find.text('Notes'), findsOneWidget);
    });
  });

  group('search', () {
    test('the back matches on every solution, not just the first', () {
      final back = leetCodeBackSearchText(
        _problem(solutions: const [_bruteForce, _hashMap]),
      ).toLowerCase();

      expect(back, contains('compare every pair'));
      expect(back, contains('hash map of complements'));
      expect(back, contains('o(n^2)'));
    });

    test('code and notes stay out — no face shows them', () {
      final searchable = leetCodeBackSearchText(
        _problem(solutions: const [_bruteForce]),
      ).toLowerCase();

      expect(searchable, isNot(contains('def brute')));
      expect(searchable, isNot(contains('never say this one first')));
    });
  });
}

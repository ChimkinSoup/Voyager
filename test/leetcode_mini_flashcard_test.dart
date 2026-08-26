// The Review Deck's grid mirrors the study deck's: fronts showing, search
// matching both faces, and a mastery ring around every tile. These pin the
// LeetCode-specific parts of that contract — the countdown rides the front
// alone, difficulty stays visible on the front, the ring reports SRS state
// rather than difficulty, and the right-click menu offers LeetCode's actions
// with no "Reverse" (a problem's two faces are not interchangeable).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/srs_mastery_color.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';
import 'package:voyager/features/study/study_flip_card.dart';

LeetCodeProblem _problem({
  String title = 'Two Sum',
  String? frontendId = '1',
  LeetCodeDifficulty difficulty = LeetCodeDifficulty.easy,
  List<String> tags = const [],
  String algorithm = 'Hash map of complements',
  String explanation = '',
  DateTime? dueAt,
  double interval = 0,
  int reviewCount = 0,
}) {
  final now = DateTime.now().toUtc();
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: title,
    questionFrontendId: frontendId,
    difficulty: difficulty,
    tags: tags,
    solutions: [
      LeetCodeSolution(algorithm: algorithm, explanation: explanation),
    ],
    solvedAt: now,
    interval: interval,
    reviewCount: reviewCount,
    dueAt: dueAt,
  );
}

Future<void> _pumpTile(
  WidgetTester tester,
  LeetCodeProblem problem, {
  List<String> keywords = const [],
  bool showBack = false,
  ValueChanged<bool>? onFlipped,
  DateTime? now,
}) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 210,
            child: LeetCodeMiniFlashcard(
              problem: problem,
              keywords: keywords,
              showBack: showBack,
              onFlipped: onFlipped ?? (_) {},
              now: now,
            ),
          ),
        ),
      ),
    ),
  ),
);

bool _showingBack(WidgetTester tester) => tester
    .widget<StudyFlipCard>(find.byType(StudyFlipCard))
    .initiallyShowingBack;

/// The mastery ring the tile is currently drawing.
Color _ringColor(WidgetTester tester) {
  final card = tester.widget<Card>(find.byType(Card).first);
  final shape = card.shape as RoundedRectangleBorder;
  return shape.side.color;
}

void main() {
  group('search', () {
    test('the front matches on id, title, description and tags', () {
      final problem = _problem(title: 'Two Sum', tags: ['hash-table']);
      final withDescription = problem.copyWith(
        description: 'Given an array of integers nums',
      );
      final front = leetCodeFrontSearchText(withDescription).toLowerCase();
      expect(front, contains('two sum'));
      expect(front, contains('1'));
      expect(front, contains('hash-table'));
      expect(front, contains('array of integers'));
    });

    test('the back matches on approach, complexity and explanation', () {
      final problem = _problem(
        algorithm: 'Two pointers',
        explanation: 'Walk inward from both ends',
      );
      final back = leetCodeBackSearchText(problem).toLowerCase();
      expect(back, contains('two pointers'));
      expect(back, contains('walk inward'));
    });

    test('code and notes are out of scope — neither face shows them', () {
      final problem = LeetCodeProblem(
        id: 'p1',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        title: 'Two Sum',
        difficulty: LeetCodeDifficulty.easy,
        solvedAt: DateTime.now().toUtc(),
        solutions: const [
          LeetCodeSolution(
            code: 'def twoSum(nums): pass',
            notes: 'revisit before the interview',
          ),
        ],
      );
      final searchable =
          '${leetCodeFrontSearchText(problem)} '
                  '${leetCodeBackSearchText(problem)}'
              .toLowerCase();
      expect(searchable, isNot(contains('def twosum')));
      expect(searchable, isNot(contains('revisit')));
    });

    test('a back-only match is the only case that turns a tile around', () {
      const keywords = ['pointer'];
      expect(
        leetCodeMatchesBackOnly(
          leetCodeSearchTextFor(
            _problem(title: 'Two Sum', algorithm: 'Two pointer walk'),
          ),
          keywords,
        ),
        isTrue,
      );
      expect(
        leetCodeMatchesBackOnly(
          leetCodeSearchTextFor(
            _problem(title: 'Linked List Pointer', algorithm: 'Hash map'),
          ),
          keywords,
        ),
        isFalse,
      );
      expect(
        leetCodeMatchesBackOnly(leetCodeSearchTextFor(_problem()), const []),
        isFalse,
      );
    });

    testWidgets('the match is marked on whichever face is showing', (
      tester,
    ) async {
      await _pumpTile(
        tester,
        _problem(title: 'Two Sum', algorithm: 'Two pointer walk'),
        keywords: ['pointer'],
        showBack: true,
      );

      expect(_showingBack(tester), isTrue);
      final marked = <String>[];
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        text.textSpan?.visitChildren((child) {
          if (child is TextSpan &&
              child.text != null &&
              child.style?.fontWeight == FontWeight.w600) {
            marked.add(child.text!);
          }
          return true;
        });
      }
      expect(marked, contains('pointer'));
    });
  });

  group('faces', () {
    testWidgets('the front carries the id and difficulty badge', (
      tester,
    ) async {
      await _pumpTile(
        tester,
        _problem(frontendId: '42', difficulty: LeetCodeDifficulty.hard),
      );

      expect(find.text('#42'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.text('Two Sum'), findsOneWidget);
    });

    testWidgets('a tap turns the tile over onto the approach', (tester) async {
      bool? reported;
      await _pumpTile(
        tester,
        _problem(algorithm: 'Hash map of complements'),
        onFlipped: (v) => reported = v,
      );

      await tester.tap(find.byType(StudyFlipCard));
      await tester.pumpAndSettle();

      expect(reported, isTrue);
      expect(find.text('Hash map of complements'), findsOneWidget);
    });

    testWidgets('a problem with no approach says so rather than sitting '
        'blank', (tester) async {
      await _pumpTile(
        tester,
        _problem(algorithm: '', explanation: ''),
        showBack: true,
      );

      expect(find.text('No approach written'), findsOneWidget);
    });
  });

  group('review countdown', () {
    testWidgets('a scheduled problem counts down in days, on the front only', (
      tester,
    ) async {
      // Both ends pinned to one clock: the countdown compares local calendar
      // days, so a duration measured from the real "now" reads a day higher
      // whenever the test happens to run late enough in the evening.
      final today = DateTime(2026, 8, 9, 9);
      final problem = _problem(
        dueAt: DateTime(2026, 8, 12, 11).toUtc(),
        interval: 3,
        reviewCount: 2,
      );

      await _pumpTile(tester, problem, now: today);
      expect(find.text('3'), findsOneWidget);

      await _pumpTile(tester, problem, showBack: true, now: today);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('a never-reviewed problem reads 0 in the error color', (
      tester,
    ) async {
      await _pumpTile(tester, _problem());

      final label = tester.widget<Text>(find.text('0'));
      final scheme = Theme.of(
        tester.element(find.byType(StudyFlipCard)),
      ).colorScheme;
      expect(label.style?.color, scheme.error.withValues(alpha: 0.55));
    });
  });

  group('mastery ring', () {
    testWidgets('reports SRS state, not difficulty', (tester) async {
      // An easy problem studied into a long interval rings green, not
      // LeetCode's easy-teal — the ring is about memory, the badge is about
      // the problem.
      final mature = _problem(
        difficulty: LeetCodeDifficulty.easy,
        interval: 40,
        reviewCount: 6,
        dueAt: DateTime.now().toUtc().add(const Duration(days: 40)),
      );
      await _pumpTile(tester, mature);

      final scheme = Theme.of(
        tester.element(find.byType(StudyFlipCard)),
      ).colorScheme;
      expect(
        _ringColor(tester),
        srsMasteryColor(reviewCount: 6, interval: 40, scheme: scheme),
      );
    });

    testWidgets('an untouched problem rings in the neutral new color', (
      tester,
    ) async {
      await _pumpTile(tester, _problem(difficulty: LeetCodeDifficulty.hard));

      final scheme = Theme.of(
        tester.element(find.byType(StudyFlipCard)),
      ).colorScheme;
      expect(
        _ringColor(tester),
        srsMasteryColor(reviewCount: 0, interval: 0, scheme: scheme),
      );
    });
  });

  testWidgets('the context menu offers LeetCode actions and no Reverse', (
    tester,
  ) async {
    await _pumpTile(tester, _problem(tags: ['array']));

    final region = tester.widget<ContextMenuRegion>(
      find.byType(ContextMenuRegion),
    );
    final labels = region.itemsBuilder!().map((item) => item.label).toList();

    expect(labels, [
      'Open details…',
      'Edit…',
      'Open on LeetCode',
      'Copy code',
      'Reset progress',
      'Delete',
    ]);
    expect(labels, isNot(contains('Reverse')));
  });
}

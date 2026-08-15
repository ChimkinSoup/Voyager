// Study and Cram on the Review Deck are the study page's two modes applied to
// problems: Study grades and writes the schedule back, Cram runs three
// in-memory buckets and must never touch it. These pin both halves, plus the
// re-queue rule that keeps a failed problem in the session.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_cram_page.dart';
import 'package:voyager/features/leetcode/leetcode_session_page.dart';
import 'package:voyager/features/study/study_flip_card.dart';

class _RecordingLeetCodeRepository implements LeetCodeRepository {
  _RecordingLeetCodeRepository(this.problems);

  List<LeetCodeProblem> problems;

  /// Every problem written back, in order — a Cram session must leave this
  /// empty.
  final saved = <LeetCodeProblem>[];

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => problems;

  @override
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  }) async {
    saved.add(problem);
    problems = [
      for (final p in problems) if (p.id == problem.id) problem else p,
    ];
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

LeetCodeProblem _problem({required String id, required String title}) {
  final now = DateTime.utc(2026, 8, 9, 12);
  return LeetCodeProblem(
    id: id,
    createdAt: now,
    updatedAt: now,
    title: title,
    questionFrontendId: id,
    difficulty: LeetCodeDifficulty.medium,
    solutions: const [LeetCodeSolution(algorithm: 'An approach')],
    solvedAt: now,
  );
}

Future<_RecordingLeetCodeRepository> _pump(
  WidgetTester tester,
  List<LeetCodeProblem> problems,
  Widget page,
) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = _RecordingLeetCodeRepository(problems);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        leetCodeRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
      ],
      child: MaterialApp(home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return repo;
}

/// Turns the card over and waits out the flip, which is what arms the
/// grading buttons. Taps the card's upper-left corner rather than its middle:
/// the centred title is its own tap target, and hitting that opens the detail
/// view instead of flipping.
Future<void> _reveal(WidgetTester tester) async {
  final card = tester.getRect(find.byType(StudyFlipCard).first);
  await tester.tapAt(card.topLeft + const Offset(40, 40));
  await tester.pumpAndSettle();
}

Future<void> _grade(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Steps back or forward through the session's history and waits for the
/// write and the card swap to land.
Future<void> _stepHistory(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('study session', () {
    testWidgets('a Good grade writes the new schedule back', (tester) async {
      final repo = await _pump(
        tester,
        [_problem(id: '1', title: 'Two Sum')],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      expect(find.text('New 1'), findsOneWidget);

      await _reveal(tester);
      await _grade(tester, 'Good');

      expect(repo.saved, hasLength(1));
      final graded = repo.saved.single;
      expect(graded.id, '1');
      expect(graded.interval, 1);
      expect(graded.reviewCount, 1);
      expect(graded.dueAt, isNotNull);
      expect(graded.isDue(now: DateTime.now().toUtc()), isFalse);

      // Nothing left that is due, so the session is over.
      expect(find.text('Session complete'), findsOneWidget);
    });

    testWidgets('a failed problem comes back before the session ends', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [_problem(id: '1', title: 'Two Sum')],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      await _reveal(tester);
      await _grade(tester, 'Fail');

      // Re-queued rather than finished: a Fail resets the interval to zero,
      // which means "see it again today".
      expect(find.text('Session complete'), findsNothing);
      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(repo.saved.single.interval, 0);

      await _reveal(tester);
      await _grade(tester, 'Good');
      expect(find.text('Session complete'), findsOneWidget);
    });

    testWidgets('an edit saved mid-session replaces the card on screen', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [_problem(id: '1', title: 'Two Sum')],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      expect(find.text('1 Two Sum'), findsOneWidget);

      // What saving the detail view's editor does: write the problem, then
      // invalidate the list the session reads. The session used to keep
      // showing the copy it queued when it opened.
      await repo.upsertProblem(repo.problems.single.copyWith(title: 'Two Sum II'));
      ProviderScope.containerOf(
        tester.element(find.byType(LeetCodeSessionPage)),
      ).invalidate(leetcodeProblemsProvider);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('1 Two Sum II'), findsOneWidget);
      expect(find.text('1 Two Sum'), findsNothing);
    });

    testWidgets('Reset progress from the card menu forgets it and moves on', (
      tester,
    ) async {
      final reviewed = _problem(id: '1', title: 'Two Sum').copyWith(
        interval: 10,
        reviewCount: 3,
        dueAt: DateTime.utc(2026, 8, 10),
      );
      final repo = await _pump(
        tester,
        [reviewed],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      expect(find.text('Review 1'), findsOneWidget);

      final card = tester.getRect(find.byType(StudyFlipCard).first);
      await tester.tapAt(
        card.topLeft + const Offset(40, 40),
        buttons: kSecondaryButton,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Reset progress'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repo.saved, hasLength(1));
      expect(repo.saved.single.interval, 0);
      expect(repo.saved.single.reviewCount, 0);
      // Reset means due now, so it comes round again this session rather than
      // ending it — and it comes round as a new problem.
      expect(find.text('Session complete'), findsNothing);
      expect(find.text('New 1'), findsOneWidget);
    });

    testWidgets('undo takes the last grade back, redo gives the same one', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [_problem(id: '1', title: 'Two Sum')],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      await _reveal(tester);
      await _grade(tester, 'Good');
      expect(find.text('Session complete'), findsOneWidget);

      // Stepping back from the completion screen, which is where a misgrade
      // on the last card is noticed.
      await _stepHistory(tester, LogicalKeyboardKey.arrowLeft);

      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(find.text('New 1'), findsOneWidget);
      final restored = repo.saved.last;
      expect(restored.reviewCount, 0);
      expect(restored.interval, 0);
      expect(
        restored.dueAt,
        isNull,
        reason: 'a never-reviewed problem carries no due date, and undoing '
            'its first grade has to put that back',
      );

      // Redo returns the rating that was given rather than asking again.
      await _stepHistory(tester, LogicalKeyboardKey.arrowRight);

      expect(repo.saved.last.reviewCount, 1);
      expect(repo.saved.last.interval, 1);
      expect(find.text('Session complete'), findsOneWidget);
    });

    testWidgets('undoing a Fail takes its re-queued copy back out', (
      tester,
    ) async {
      await _pump(
        tester,
        [
          _problem(id: '1', title: 'Two Sum'),
          _problem(id: '2', title: 'Merge Intervals'),
        ],
        const LeetCodeSessionPage(problemIds: {'1', '2'}),
      );

      await _reveal(tester);
      await _grade(tester, 'Fail');
      // Failed, so it went to the back of the round rather than out of it —
      // and it is a learning problem now rather than a new one.
      expect(find.text('2 Merge Intervals'), findsOneWidget);
      expect(find.text('New 1'), findsOneWidget);
      expect(find.text('Learning 1'), findsOneWidget);

      await _stepHistory(tester, LogicalKeyboardKey.arrowLeft);

      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(
        find.text('New 2'),
        findsOneWidget,
        reason: 'the round holds the same two problems it started with — the '
            're-queued copy left with the grade that made it',
      );
    });

    testWidgets('redo cannot run past the furthest problem reached', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [
          _problem(id: '1', title: 'Two Sum'),
          _problem(id: '2', title: 'Merge Intervals'),
        ],
        const LeetCodeSessionPage(problemIds: {'1', '2'}),
      );

      await _stepHistory(tester, LogicalKeyboardKey.arrowRight);

      // Nothing has been graded, so there is nothing to redo: the session
      // stays on its first problem rather than skipping it unseen.
      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(repo.saved, isEmpty);
    });

    testWidgets('a grade given after an undo replaces the one taken back', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [_problem(id: '1', title: 'Two Sum')],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      await _reveal(tester);
      await _grade(tester, 'Easy');
      await _stepHistory(tester, LogicalKeyboardKey.arrowLeft);

      await _reveal(tester);
      await _grade(tester, 'Good');
      expect(repo.saved.last.interval, 1, reason: 'Good, not Easy\'s 3 days');

      // The Easy that was taken back is gone for good — redo has nothing left
      // to replay.
      await _stepHistory(tester, LogicalKeyboardKey.arrowRight);
      expect(repo.saved.last.interval, 1);
    });

    testWidgets('the session only asks the problems it was handed', (
      tester,
    ) async {
      await _pump(
        tester,
        [
          _problem(id: '1', title: 'Two Sum'),
          _problem(id: '2', title: 'Merge Intervals'),
        ],
        const LeetCodeSessionPage(problemIds: {'2'}),
      );

      expect(find.text('New 1'), findsOneWidget);
      expect(find.text('2 Merge Intervals'), findsOneWidget);
      expect(find.text('1 Two Sum'), findsNothing);
    });
  });

  group('cram session', () {
    testWidgets('two passes graduate a problem and never touch its SRS state', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [_problem(id: '1', title: 'Two Sum')],
        const LeetCodeCramPage(problemIds: {'1'}),
      );

      expect(find.text('Cram mode'), findsOneWidget);

      // Bucket 0 → 1 → 2, the pass button being the right arrow.
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byIcon(PhosphorIconsRegular.arrowRight));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      expect(find.text('All problems mastered'), findsOneWidget);
      expect(repo.saved, isEmpty);
    });

    testWidgets('U steps back a card and R steps forward again', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        [
          _problem(id: '1', title: 'Two Sum'),
          _problem(id: '2', title: 'Merge Intervals'),
        ],
        const LeetCodeCramPage(problemIds: {'1', '2'}),
      );

      await tester.tap(find.byIcon(PhosphorIconsRegular.arrowRight));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('2 Merge Intervals'), findsOneWidget);

      // The arrows still decide in cram, so stepping back is U — and it only
      // moves the card, with nothing written either way.
      await _stepHistory(tester, LogicalKeyboardKey.keyU);
      expect(find.text('1 Two Sum'), findsOneWidget);

      await _stepHistory(tester, LogicalKeyboardKey.keyR);
      expect(find.text('2 Merge Intervals'), findsOneWidget);

      // Nothing beyond the furthest card reached to step forward into.
      await _stepHistory(tester, LogicalKeyboardKey.keyR);
      expect(find.text('2 Merge Intervals'), findsOneWidget);
      expect(repo.saved, isEmpty);
    });
  });
}

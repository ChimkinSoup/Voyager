// Phase 17 LeetCode fixes: closing an edited problem asks before discarding
// (BUG-144), the Track form opens with the name focused (BUG-145), Reset
// progress says so with an Undo (BUG-146), "today" and "due" follow the clock
// (BUG-147), tags differing only by case are one tag (BUG-148), and the
// stacked dashboard keeps a usable feed at the minimum window size (BUG-150).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_dashboard.dart';
import 'package:voyager/features/leetcode/leetcode_providers.dart';
import 'package:voyager/features/leetcode/leetcode_recent_completions.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';
import 'package:voyager/features/leetcode/leetcode_tag_matrix.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

import 'fakes/memory_session_checkpoints.dart';

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

final _t0 = DateTime.utc(2026, 9, 1, 12);

LeetCodeProblem _problem({
  String id = 'p1',
  String title = 'Two Sum',
  List<String> tags = const [],
  String? description,
  DateTime? dueAt,
  int reviewCount = 0,
  double interval = 0,
  double ease = 2.5,
}) => LeetCodeProblem(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  title: title,
  difficulty: LeetCodeDifficulty.easy,
  tags: tags,
  description: description,
  solvedAt: _t0,
  dueAt: dueAt,
  reviewCount: reviewCount,
  interval: interval,
  ease: ease,
);

/// A real repository on an in-memory database, seeded with [problems], and
/// [child] built under it.
Future<DriftLeetCodeRepository> _pump(
  WidgetTester tester, {
  List<LeetCodeProblem> problems = const [],
  required Widget child,
  Size size = const Size(1280, 900),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftLeetCodeRepository(db);
  for (final p in problems) {
    await repo.upsertProblem(p);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        leetCodeRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        memorySessionCheckpoints(),
        ...overrides,
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// A button that opens the Track form, as an edit of [existing] if given.
Widget _opener({LeetCodeProblem? existing}) => Consumer(
  builder: (context, ref, _) => TextButton(
    onPressed: () => showLeetCodeTrackModal(context, ref, existing: existing),
    child: const Text('open'),
  ),
);

/// The field labelled [label]. The label is drawn outside the [TextField].
Finder _field(String label) => find.descendant(
  of: find.ancestor(
    of: find.text(label).first,
    matching: find.byType(VoyagerTextField),
  ),
  matching: find.byType(EditableText),
);

/// Runs the menu's Reset progress on problem p1, as a tile would.
Widget _resetButton() => Consumer(
  builder: (context, ref, _) => TextButton(
    onPressed: () async {
      final problem = (await ref
          .read(leetCodeRepositoryProvider)
          .getProblem('p1'))!;
      if (!context.mounted) return;
      leetCodeProblemMenuItems(
        context: context,
        ref: ref,
        problem: problem,
        onOpenDetail: () {},
      ).firstWhere((i) => i.label == 'Reset progress').onTap!();
    },
    child: const Text('reset'),
  ),
);

void main() {
  group('BUG-144 closing an edited problem', () {
    Future<void> openEdit(WidgetTester tester) async {
      final problem = _problem(description: 'Find two numbers.');
      await _pump(
        tester,
        problems: [problem],
        child: _opener(existing: problem),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Esc with no change closes at once', (tester) async {
      await openEdit(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('Save changes'), findsNothing);
    });

    testWidgets('Esc or the X with a change asks first', (tester) async {
      await openEdit(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Find two numbers.'),
        'Find two numbers. EDITED',
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Find two numbers. EDITED'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Save changes'), findsNothing);
    });
  });

  testWidgets(
    'BUG-144 on Android an edit can\'t be dragged shut, a new problem can',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final problem = _problem();
      await _pump(
        tester,
        problems: [problem],
        child: Column(
          children: [
            _opener(existing: problem),
            Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showLeetCodeTrackModal(context, ref),
                child: const Text('new'),
              ),
            ),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).enableDrag,
        isFalse,
      );
      Navigator.of(tester.element(find.text('Save changes'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('new'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).enableDrag,
        isTrue,
      );
    },
  );

  testWidgets('BUG-145 the form opens with the problem name focused', (
    tester,
  ) async {
    await _pump(tester, child: _opener());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(_field('Problem name'))
          .focusNode
          .hasPrimaryFocus,
      isTrue,
    );
  });

  testWidgets('BUG-146 Reset progress shows a toast whose Undo restores the '
      'schedule', (tester) async {
    final due = DateTime.utc(2026, 12, 1);
    final repo = await _pump(
      tester,
      problems: [_problem(dueAt: due, reviewCount: 3, interval: 3, ease: 2.3)],
      child: _resetButton(),
    );

    await tester.tap(find.text('reset'));
    await tester.pumpAndSettle();
    expect(find.text('Progress reset for "Two Sum"'), findsOneWidget);
    expect((await repo.getProblem('p1'))!.reviewCount, 0);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undone = (await repo.getProblem('p1'))!;
    expect(undone.reviewCount, 3);
    expect(undone.interval, 3);
    expect(undone.ease, 2.3);
    expect(undone.dueAt, due);
  });

  testWidgets('BUG-146 Undo keeps a review graded since the reset', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      problems: [
        _problem(
          dueAt: DateTime.utc(2026, 12, 1),
          reviewCount: 3,
          interval: 3,
          ease: 2.3,
        ),
      ],
      child: _resetButton(),
    );
    await tester.tap(find.text('reset'));
    await tester.pumpAndSettle();
    // A grade lands while the toast is still up.
    final graded = (await repo.getProblem(
      'p1',
    ))!.copyWith(reviewCount: 1, interval: 1, dueAt: DateTime.utc(2026, 9, 2));
    await tester.runAsync(() => repo.upsertProblem(graded));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final kept = (await repo.getProblem('p1'))!;
    expect(kept.reviewCount, 1);
    expect(kept.interval, 1);
    expect(find.textContaining('Reviewed since the reset'), findsOneWidget);
  });

  group('BUG-147', () {
    testWidgets('the clock moves on when a problem comes due', (tester) async {
      final container = ProviderContainer(
        overrides: [
          leetcodeProblemsProvider.overrideWith(
            (ref) async => [
              _problem(
                dueAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
                reviewCount: 1,
              ),
            ],
          ),
        ],
      );
      final seen = <DateTime>[];
      container.listen(
        leetCodeClockProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      await tester.pump();
      seen.clear();
      await tester.pump(const Duration(minutes: 5, seconds: 1));
      expect(seen, isNotEmpty);
      // Disposed here, not in a tear-down: the next tick's timer has to be
      // gone before the test's own pending-timer check.
      container.dispose();
    });

    testWidgets('the deck counts what is due at the clock\'s time', (
      tester,
    ) async {
      final dueAt = DateTime.now().toUtc().add(const Duration(hours: 2));
      final clock = StateProvider((ref) => DateTime.now());
      late WidgetRef widgetRef;
      await _pump(
        tester,
        problems: [_problem(dueAt: dueAt, reviewCount: 1, interval: 1)],
        overrides: [
          leetCodeClockProvider.overrideWith((ref) => ref.watch(clock)),
        ],
        size: const Size(1400, 1000),
        child: Consumer(
          builder: (context, ref, _) {
            widgetRef = ref;
            return const SafeArea(child: LeetCodeReviewDeck());
          },
        ),
      );
      expect(find.textContaining('· 0 due'), findsOneWidget);
      widgetRef.read(clock.notifier).state = dueAt.toLocal().add(
        const Duration(minutes: 1),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('· 1 due'), findsOneWidget);
    });
  });

  group('BUG-148 tags differing only by case', () {
    testWidgets('are saved as one, first spelling kept', (tester) async {
      final repo = await _pump(tester, child: _opener());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Problem name'), 'Draft Problem v2');
      await tester.enterText(_field('Tags'), '#Draft, tag2 #draft #tag2 #TAG2');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final saved = (await repo.listProblems()).single;
      expect(saved.tags, ['Draft', 'tag2']);
    });

    testWidgets('are one pill in the tag matrix', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LeetCodeTagMatrix(
              problems: [
                _problem(id: 'a', tags: ['Draft']),
                _problem(id: 'b', tags: ['draft']),
              ],
            ),
          ),
        ),
      );
      expect(find.text('#Draft (2)'), findsOneWidget);
      expect(find.textContaining('#draft'), findsNothing);
    });
  });

  testWidgets('BUG-150 the stacked dashboard keeps a usable feed at the '
      'minimum window size', (tester) async {
    await _pump(
      tester,
      problems: [
        for (var i = 0; i < 6; i++)
          _problem(id: 'p$i', title: 'Problem $i', tags: ['t$i']),
      ],
      // The dashboard's share of a 720×520 window.
      size: const Size(620, 440),
      overrides: [
        leetcodeQuestionCountsProvider.overrideWith(
          (ref) async =>
              const LeetCodeQuestionCounts(easy: 900, medium: 2000, hard: 900),
        ),
      ],
      child: const LeetCodeDashboard(),
    );
    expect(
      tester.getSize(find.byType(LeetCodeRecentCompletions)).height,
      greaterThanOrEqualTo(240),
    );
    // Scrolled to the end, the matrix clears the Track button's corner.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(LeetCodeTagMatrix)).bottom,
      lessThanOrEqualTo(440 - 80),
    );
  });
}

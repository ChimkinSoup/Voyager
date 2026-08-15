// The Review Deck is a workbench, not a slideshow: every tracked problem is
// on screen at once as a mini flashcard, narrowed by keyword, difficulty and
// tag, with Study and Cram picking up exactly what the narrowing left. These
// pin that contract — including the part that is easy to get wrong, that a
// session inherits the filtered set rather than the whole library.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_cram_page.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';
import 'package:voyager/features/leetcode/leetcode_session_page.dart';

class _FakeLeetCodeRepository implements LeetCodeRepository {
  _FakeLeetCodeRepository(this.problems);

  final List<LeetCodeProblem> problems;

  @override
  Future<List<LeetCodeProblem>> listProblems({bool includeDeleted = false}) async =>
      problems;

  @override
  Future<LeetCodeProblem?> getProblem(String id) async =>
      problems.where((p) => p.id == id).firstOrNull;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Swallows the pushes a grade fires. The real service is built from
/// Firebase, which isn't initialised under `flutter test`.
class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

final _now = DateTime.utc(2026, 8, 9, 12);

LeetCodeProblem _problem({
  required String id,
  required String title,
  LeetCodeDifficulty difficulty = LeetCodeDifficulty.medium,
  List<String> tags = const [],
  String algorithm = 'An approach',
  DateTime? dueAt,
  double interval = 0,
  int reviewCount = 0,
}) => LeetCodeProblem(
  id: id,
  createdAt: _now,
  updatedAt: _now,
  title: title,
  questionFrontendId: id,
  difficulty: difficulty,
  tags: tags,
  solutions: [LeetCodeSolution(algorithm: algorithm)],
  solvedAt: _now,
  dueAt: dueAt,
  interval: interval,
  reviewCount: reviewCount,
);

/// Scheduled far enough out that it is not due — the counterpart to the
/// never-reviewed problems, which are due immediately.
LeetCodeProblem _scheduled({
  required String id,
  required String title,
  LeetCodeDifficulty difficulty = LeetCodeDifficulty.medium,
  List<String> tags = const [],
}) => _problem(
  id: id,
  title: title,
  difficulty: difficulty,
  tags: tags,
  dueAt: DateTime.now().toUtc().add(const Duration(days: 30)),
  interval: 30,
  reviewCount: 4,
);

Future<void> _pumpDeck(
  WidgetTester tester,
  List<LeetCodeProblem> problems,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        leetCodeRepositoryProvider.overrideWithValue(
          _FakeLeetCodeRepository(problems),
        ),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SafeArea(child: LeetCodeReviewDeck())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pump();
}

Finder _button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(GlassButton),
);

void main() {
  testWidgets('every tracked problem shows as a mini flashcard', (
    tester,
  ) async {
    await _pumpDeck(tester, [
      _problem(id: '1', title: 'Two Sum'),
      _problem(id: '2', title: 'Valid Parentheses'),
      _problem(id: '3', title: 'Merge Intervals'),
    ]);

    expect(find.byType(LeetCodeMiniFlashcard), findsNWidgets(3));
    expect(find.text('Two Sum'), findsOneWidget);
    expect(find.text('Merge Intervals'), findsOneWidget);
  });

  testWidgets('an empty deck offers the action that fills it', (tester) async {
    await _pumpDeck(tester, const []);

    expect(find.byType(LeetCodeMiniFlashcard), findsNothing);
    expect(find.text('Nothing tracked yet'), findsOneWidget);
    // The way out is a button, not a sentence naming a control elsewhere.
    expect(_button('Track a problem'), findsOneWidget);
  });

  group('narrowing', () {
    testWidgets('the search bar filters on both faces', (tester) async {
      await _pumpDeck(tester, [
        _problem(id: '1', title: 'Two Sum', algorithm: 'Hash map'),
        _problem(id: '2', title: 'Valid Parentheses', algorithm: 'Stack'),
      ]);

      await _search(tester, 'stack');

      // Matched on the back, so that tile is the one on screen — turned
      // around to the side that actually matched.
      expect(find.byType(LeetCodeMiniFlashcard), findsOneWidget);
      expect(find.text('Stack'), findsOneWidget);
    });

    testWidgets('the difficulty pills narrow the grid', (tester) async {
      await _pumpDeck(tester, [
        _problem(id: '1', title: 'Two Sum', difficulty: LeetCodeDifficulty.easy),
        _problem(
          id: '2',
          title: 'Merge Intervals',
          difficulty: LeetCodeDifficulty.medium,
        ),
        _problem(
          id: '3',
          title: 'Median of Two Sorted Arrays',
          difficulty: LeetCodeDifficulty.hard,
        ),
      ]);

      await tester.tap(find.text('Hard').first);
      await tester.pump();

      expect(find.byType(LeetCodeMiniFlashcard), findsOneWidget);
      expect(find.text('Median of Two Sorted Arrays'), findsOneWidget);
      expect(find.text('Two Sum'), findsNothing);

      // Tapping the same pill again clears the narrowing rather than
      // stranding the user in a filtered view with no obvious way out.
      await tester.tap(find.text('Hard').first);
      await tester.pump();
      expect(find.byType(LeetCodeMiniFlashcard), findsNWidgets(3));
    });

    testWidgets('the counts follow the filter', (tester) async {
      await _pumpDeck(tester, [
        _problem(id: '1', title: 'Two Sum', difficulty: LeetCodeDifficulty.easy),
        _scheduled(
          id: '2',
          title: 'Merge Intervals',
          difficulty: LeetCodeDifficulty.easy,
        ),
        _problem(
          id: '3',
          title: 'Median of Two Sorted Arrays',
          difficulty: LeetCodeDifficulty.hard,
        ),
      ]);

      expect(find.text('3 problems · 2 due'), findsOneWidget);

      await tester.tap(find.text('Easy').first);
      await tester.pump();

      expect(find.text('2 problems of 3 · 1 due'), findsOneWidget);
    });
  });

  group('sessions', () {
    testWidgets('Study is offered only when something is due', (tester) async {
      await _pumpDeck(tester, [
        _scheduled(id: '1', title: 'Two Sum'),
        _scheduled(id: '2', title: 'Merge Intervals'),
      ]);

      expect(tester.widget<GlassButton>(_button('Study')).onPressed, isNull);
      // Cram ignores the schedule, so it stays available.
      expect(
        tester.widget<GlassButton>(_button('Cram')).onPressed,
        isNotNull,
      );
    });

    testWidgets('Study opens a session over what is due', (tester) async {
      await _pumpDeck(tester, [
        _problem(id: '1', title: 'Two Sum'),
        _scheduled(id: '2', title: 'Merge Intervals'),
      ]);

      await tester.tap(_button('Study'));
      await tester.pumpAndSettle();

      expect(find.byType(LeetCodeSessionPage), findsOneWidget);
      // The due problem is the one being asked; the scheduled one waits. The
      // full-size card titles itself with the problem's id, as it always has.
      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(find.text('2 Merge Intervals'), findsNothing);
    });

    testWidgets('a filtered deck studies only what it was showing', (
      tester,
    ) async {
      await _pumpDeck(tester, [
        _problem(id: '1', title: 'Two Sum', tags: ['hash-table']),
        _problem(id: '2', title: 'Merge Intervals', tags: ['sorting']),
      ]);

      await _search(tester, 'Merge');
      await tester.tap(_button('Study'));
      await tester.pumpAndSettle();

      final session = tester.widget<LeetCodeSessionPage>(
        find.byType(LeetCodeSessionPage),
      );
      expect(session.problemIds, {'2'});
    });

    testWidgets('Cram takes the filtered set too', (tester) async {
      await _pumpDeck(tester, [
        _problem(id: '1', title: 'Two Sum', difficulty: LeetCodeDifficulty.easy),
        _scheduled(
          id: '2',
          title: 'Merge Intervals',
          difficulty: LeetCodeDifficulty.hard,
        ),
      ]);

      await tester.tap(find.text('Hard').first);
      await tester.pump();
      await tester.tap(_button('Cram'));
      await tester.pumpAndSettle();

      final cram = tester.widget<LeetCodeCramPage>(
        find.byType(LeetCodeCramPage),
      );
      // Not due, but cram drills everything on screen regardless.
      expect(cram.problemIds, {'2'});
      expect(find.text('Cram mode'), findsOneWidget);
    });
  });
}

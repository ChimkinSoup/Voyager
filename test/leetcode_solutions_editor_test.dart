// The solutions editor numbers its groups by position rather than storing a
// title with each one, and shows no number at all while there is only one
// group — a lone solution has nothing to be told apart from. These pin both
// halves of that, plus what reaches the repository on save.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/enums.dart';
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
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

const _bruteForce = LeetCodeSolution(
  algorithm: 'Compare every pair',
  timeComplexity: 'O(n^2)',
  explanation: 'Two nested loops',
  code: 'brute()',
  notes: 'open with this',
);

const _hashMap = LeetCodeSolution(
  algorithm: 'Hash map of complements',
  timeComplexity: 'O(n)',
  explanation: 'Look up the complement',
  codeLanguage: 'cpp',
  code: 'hashed()',
);

LeetCodeProblem _problem({List<LeetCodeSolution> solutions = const []}) {
  final now = DateTime.utc(2026, 8, 14, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    solutions: solutions,
    solvedAt: now,
  );
}

Future<_RecordingLeetCodeRepository> _openModal(
  WidgetTester tester, {
  LeetCodeProblem? existing,
}) async {
  final repo = _RecordingLeetCodeRepository();
  // Tall enough that the form needs no scrolling — see the note in
  // leetcode_examples_editor_test.dart about the pinned close button.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
              onPressed: () =>
                  showLeetCodeTrackModal(context, ref, existing: existing),
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

/// The label of a [VoyagerTextField] is painted by its border rather than
/// mounted as a `Text`, so a group's boxes are found by hint instead — one per
/// solution, in display order. Hints stay in the tree at zero opacity once
/// typed into, which is what makes them a stable handle.
const _algorithmHint = 'Core approach in a sentence or two';

/// The algorithm box of the [index]-th solution group, counting from zero.
Finder _algorithmField(int index) => find
    .descendant(
      of: find
          .ancestor(
            of: find.text(_algorithmHint).at(index),
            matching: find.byType(TextField),
          )
          .first,
      matching: find.byType(EditableText),
    )
    .first;

String _algorithmText(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_algorithmField(index)).controller.text;

Future<void> _addSolution(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Add solution'));
  await tester.tap(find.text('Add solution'));
  await tester.pumpAndSettle();
}

Future<void> _removeSolution(WidgetTester tester, int number) async {
  final row = find
      .ancestor(of: find.text('Solution $number'), matching: find.byType(Row))
      .first;
  final button = find.descendant(
    of: row,
    matching: find.byTooltip('Remove solution'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _moveSolution(
  WidgetTester tester,
  int number, {
  required bool up,
}) async {
  final row = find
      .ancestor(of: find.text('Solution $number'), matching: find.byType(Row))
      .first;
  final button = find.descendant(
    of: row,
    matching: find.byTooltip(up ? 'Move solution up' : 'Move solution down'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a single solution gets no heading and no remove button', (
    tester,
  ) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce]),
    );

    expect(find.text('Solutions'), findsOneWidget);
    expect(find.text('Solution 1'), findsNothing);
    expect(find.text(_algorithmHint), findsOneWidget);
    expect(find.byTooltip('Remove solution'), findsNothing);
    expect(find.byTooltip('Move solution up'), findsNothing);
    expect(find.byTooltip('Move solution down'), findsNothing);
    expect(_algorithmText(tester, 0), 'Compare every pair');
  });

  testWidgets('a problem with nothing written down still opens on one group', (
    tester,
  ) async {
    await _openModal(tester, existing: _problem());

    expect(find.text(_algorithmHint), findsOneWidget);
    expect(find.text('Solution 1'), findsNothing);
  });

  testWidgets('a tracked problem opens with its solutions numbered in order', (
    tester,
  ) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    expect(find.text('Solution 1'), findsOneWidget);
    expect(find.text('Solution 2'), findsOneWidget);
    expect(find.text('Solution 3'), findsNothing);
    expect(_algorithmText(tester, 0), 'Compare every pair');
    expect(_algorithmText(tester, 1), 'Hash map of complements');
  });

  testWidgets('Add solution names the one that was already there', (
    tester,
  ) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce]),
    );

    await _addSolution(tester);

    // The lone group had no heading; adding a second one gives both a name.
    expect(find.text('Solution 1'), findsOneWidget);
    expect(find.text('Solution 2'), findsOneWidget);
    expect(_algorithmText(tester, 0), 'Compare every pair');
    expect(_algorithmText(tester, 1), isEmpty);
  });

  testWidgets('deleting the first solution renumbers the rest', (tester) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    await _removeSolution(tester, 1);

    // Down to one group, so the heading goes away again — and the survivor
    // kept its own text rather than the deleted group's box being relabelled.
    expect(find.text('Solution 1'), findsNothing);
    expect(find.text('Solution 2'), findsNothing);
    expect(_algorithmText(tester, 0), 'Hash map of complements');
  });

  testWidgets('moving a solution up swaps display order', (tester) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    await _moveSolution(tester, 2, up: true);

    expect(_algorithmText(tester, 0), 'Hash map of complements');
    expect(_algorithmText(tester, 1), 'Compare every pair');
  });

  testWidgets('moving a solution down swaps display order', (tester) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    await _moveSolution(tester, 1, up: false);

    expect(_algorithmText(tester, 0), 'Hash map of complements');
    expect(_algorithmText(tester, 1), 'Compare every pair');
  });

  testWidgets('saving after a reorder writes solutions in the new order', (
    tester,
  ) async {
    final repo = await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    await _moveSolution(tester, 2, up: true);
    await _save(tester, 'Save changes');

    final saved = repo.saved.single.solutions;
    expect(saved.map((s) => s.algorithm).toList(), [
      'Hash map of complements',
      'Compare every pair',
    ]);
    // The problem's own language follows the first solution after reorder.
    expect(repo.saved.single.codeLanguage, 'cpp');
  });

  testWidgets('end solutions cannot move past the list edge', (tester) async {
    await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    IconButton buttonFor(Finder tooltip) => tester.widget<IconButton>(
      find.ancestor(of: tooltip, matching: find.byType(IconButton)).first,
    );

    final firstUp = find.descendant(
      of: find
          .ancestor(of: find.text('Solution 1'), matching: find.byType(Row))
          .first,
      matching: find.byTooltip('Move solution up'),
    );
    final lastDown = find.descendant(
      of: find
          .ancestor(of: find.text('Solution 2'), matching: find.byType(Row))
          .first,
      matching: find.byTooltip('Move solution down'),
    );

    expect(buttonFor(firstUp).onPressed, isNull);
    expect(buttonFor(lastDown).onPressed, isNull);
  });

  testWidgets('saving writes every solution, dropping the blank ones', (
    tester,
  ) async {
    final repo = await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    // A third group the user opened and never filled in.
    await _addSolution(tester);
    await _save(tester, 'Save changes');

    final saved = repo.saved.single.solutions;
    expect(saved.length, 2);
    expect(saved.first.algorithm, 'Compare every pair');
    expect(saved.first.notes, 'open with this');
    expect(saved.last.algorithm, 'Hash map of complements');
  });

  testWidgets('each solution keeps its own language', (tester) async {
    final repo = await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce, _hashMap]),
    );

    await _save(tester, 'Save changes');

    final saved = repo.saved.single;
    expect(saved.solutions.first.codeLanguage, 'python');
    expect(saved.solutions.last.codeLanguage, 'cpp');
    // The problem's own language — what inline code in the statement is
    // tokenized with — follows the first solution.
    expect(saved.codeLanguage, 'python');
  });

  testWidgets('a new solution typed into is what gets saved', (tester) async {
    final repo = await _openModal(
      tester,
      existing: _problem(solutions: const [_bruteForce]),
    );

    await _addSolution(tester);
    await tester.enterText(_algorithmField(1), 'Sliding window');
    await tester.pumpAndSettle();
    await _save(tester, 'Save changes');

    expect(repo.saved.single.solutions.length, 2);
    expect(repo.saved.single.solutions.last.algorithm, 'Sliding window');
  });
}

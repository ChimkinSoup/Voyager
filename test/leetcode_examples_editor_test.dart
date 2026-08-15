// The examples editor numbers its boxes by position rather than storing a
// title with each one. These pin what that buys: adding appends the next
// number, and deleting any example closes the gap instead of leaving
// "Example 1, Example 3" behind.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
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
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

LeetCodeProblem _problem({List<String> examples = const []}) {
  final now = DateTime.utc(2026, 8, 12, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    examples: examples,
    solvedAt: now,
  );
}

Future<_RecordingLeetCodeRepository> _openModal(
  WidgetTester tester, {
  LeetCodeProblem? existing,
  LeetCodeApiQuestion? prefill,
}) async {
  final repo = _RecordingLeetCodeRepository();
  // Tall enough that the whole form fits without scrolling. On the default
  // 600px-high view, `ensureVisible` parks whichever row is being tapped at
  // the top of the sheet — directly under the pinned close button, whose 48px
  // minimum touch target then swallows the tap.
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // The tags field's completion pool reaches for databaseProvider, which
  // otherwise opens the real on-disk voyager.sqlite — see widget_test.dart.
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
                existing: existing,
                prefill: prefill,
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

/// The text currently in the box under the "Example [number]" heading.
String _exampleText(WidgetTester tester, int number) {
  final field = find.descendant(
    of: find
        .ancestor(
          of: find.text('Example $number'),
          matching: find.byType(Column),
        )
        .first,
    matching: find.byType(EditableText),
  );
  return tester.widget<EditableText>(field.first).controller.text;
}

Future<void> _removeExample(WidgetTester tester, int number) async {
  final row = find
      .ancestor(of: find.text('Example $number'), matching: find.byType(Row))
      .first;
  final button = find.descendant(of: row, matching: find.byType(IconButton));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a tracked problem opens with its examples numbered in order', (
    tester,
  ) async {
    await _openModal(
      tester,
      existing: _problem(
        examples: const ['first body', 'second body', 'third body'],
      ),
    );

    expect(find.text('Example 1'), findsOneWidget);
    expect(find.text('Example 2'), findsOneWidget);
    expect(find.text('Example 3'), findsOneWidget);
    expect(find.text('Example 4'), findsNothing);
    expect(_exampleText(tester, 1), 'first body');
    expect(_exampleText(tester, 3), 'third body');
  });

  testWidgets('a problem tracked before examples existed opens with none', (
    tester,
  ) async {
    await _openModal(tester, existing: _problem());

    expect(find.text('Examples'), findsOneWidget);
    expect(find.text('Example 1'), findsNothing);
  });

  testWidgets('a new problem starts with the ones the API returned', (
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
        topicTags: ['array'],
        examples: ['first body', 'second body'],
      ),
    );

    expect(_exampleText(tester, 1), 'first body');
    expect(_exampleText(tester, 2), 'second body');

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.saved.single.examples, ['first body', 'second body']);
  });

  testWidgets('Add example appends the next number', (tester) async {
    await _openModal(
      tester,
      existing: _problem(examples: const ['first body']),
    );

    await tester.ensureVisible(find.text('Add example'));
    await tester.tap(find.text('Add example'));
    await tester.pumpAndSettle();

    expect(find.text('Example 2'), findsOneWidget);
    expect(_exampleText(tester, 2), isEmpty);
  });

  testWidgets('deleting the middle example renumbers the rest', (tester) async {
    await _openModal(
      tester,
      existing: _problem(
        examples: const ['first body', 'second body', 'third body'],
      ),
    );

    await _removeExample(tester, 2);

    expect(find.text('Example 3'), findsNothing);
    // The survivors keep their own text, so "Example 2" is now the third one
    // rather than the deleted second one's box relabelled.
    expect(_exampleText(tester, 1), 'first body');
    expect(_exampleText(tester, 2), 'third body');
  });

  testWidgets('saving writes the edited examples, dropping empty boxes', (
    tester,
  ) async {
    final repo = await _openModal(
      tester,
      existing: _problem(examples: const ['first body', 'second body']),
    );

    await _removeExample(tester, 1);
    await tester.ensureVisible(find.text('Add example'));
    await tester.tap(find.text('Add example'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(repo.saved.single.examples, ['second body']);
  });
}

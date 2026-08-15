// Retrack re-pulls a problem's metadata from LeetCode over the top of the form.
// What it must never do is take the user's own writing with it, so almost every
// assertion here is about what *survived* the overwrite rather than what
// changed. The two flows reach the API by different keys — a new entry by the
// user's latest submission, an edit by the name in the field — and only the
// edit keeps its title, which is what the last three tests pin.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/leetcode_api_client.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
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

class _StubSettingsRepository implements SettingsRepository {
  _StubSettingsRepository(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> getSettings() async => settings;

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Every call sleeps a beat so the in-flight toast gets a frame to mount in.
/// The toast's dismiss is a listener on the widget, so a lookup that resolved
/// before the overlay had built would leave the spinner on screen forever —
/// which real network calls never do, but an instant fake would.
class _FakeLeetCodeApi extends LeetCodeApiClient {
  _FakeLeetCodeApi({this.recent, this.searchHit});

  final LeetCodeApiQuestion? recent;
  final LeetCodeApiQuestion? searchHit;

  final searchedFor = <String>[];

  static const _latency = Duration(milliseconds: 20);

  @override
  Future<LeetCodeApiQuestion?> fetchMostRecentAcceptedSubmission(
    String username,
  ) async {
    await Future<void>.delayed(_latency);
    return recent;
  }

  @override
  Future<List<LeetCodeApiQuestion>> searchByTitle(
    String query, {
    int limit = 8,
  }) async {
    await Future<void>.delayed(_latency);
    searchedFor.add(query);
    return searchHit == null ? const [] : [searchHit!];
  }
}

const _twoSum = LeetCodeApiQuestion(
  questionId: '1',
  questionFrontendId: '1',
  title: 'Two Sum',
  titleSlug: 'two-sum',
  difficulty: LeetCodeDifficulty.easy,
  // "Hash Table" is deliberately two words: LeetCode names its topics in prose,
  // and a retrack has to file each one as a single tag rather than a tag per
  // word. See multi_word_tags_test.dart for the rest of that behaviour.
  topicTags: ['Array', 'Hash Table'],
  description: 'Return indices of the two numbers that add up to target.',
  examples: ['Input: nums = [2,7,11,15], target = 9\nOutput: [0,1]'],
  submissionLanguage: 'cpp',
);

/// The same question as it comes back from a title lookup: an edit has no
/// submission behind it, so there is no language to carry across.
final _twoSumBySearch = _twoSum.withSubmissionLanguage(null);

LeetCodeProblem _stale({String title = 'Two Sum'}) {
  final now = DateTime.utc(2026, 8, 14, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: title,
    questionFrontendId: '999',
    titleSlug: 'wrong-slug',
    difficulty: LeetCodeDifficulty.hard,
    tags: const ['stale-tag'],
    description: 'A statement typed from memory.',
    examples: const ['Input: garbage'],
    solutions: const [
      LeetCodeSolution(
        algorithm: 'Hash map of complements',
        timeComplexity: 'O(n)',
        explanation: 'Look up the complement',
        codeLanguage: 'java',
        code: 'hashed()',
        notes: 'open with this',
      ),
    ],
    solvedAt: now,
    interval: 6,
    reviewCount: 3,
  );
}

Future<_RecordingLeetCodeRepository> _openModal(
  WidgetTester tester, {
  required _FakeLeetCodeApi api,
  LeetCodeProblem? existing,
  String? username,
}) async {
  final repo = _RecordingLeetCodeRepository();
  // Tall enough that the form needs no scrolling, so nothing parks under the
  // pinned close button — same reason the other track-modal tests do it.
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
        leetCodeApiClientProvider.overrideWithValue(api),
        settingsRepositoryProvider.overrideWithValue(
          _StubSettingsRepository(AppSettings(leetcodeUsername: username)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              // Warm the settings the same way the real shell does — every
              // page watches them, so by the time the Track flow reads the
              // saved username it is never still loading.
              ref.watch(settingsProvider);
              return TextButton(
                onPressed: () =>
                    showLeetCodeTrackModal(context, ref, existing: existing),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tapRetrack(WidgetTester tester) async {
  // The confirm dialog's own button is labelled "Retrack" too, but it only
  // exists after this one has been pressed.
  final button = find.byWidgetPredicate(
    (widget) => widget is GlassButton && widget.label == 'Retrack',
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  // One frame to mount the in-flight toast, then long enough for the fake
  // lookup to land.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// The algorithm box of the only solution group — [VoyagerTextField] paints its
/// label in the border rather than mounting a `Text`, so boxes are found by
/// hint. See leetcode_solutions_editor_test.dart.
Finder _algorithmField() => find
    .descendant(
      of: find
          .ancestor(
            of: find.text('Core approach in a sentence or two'),
            matching: find.byType(TextField),
          )
          .first,
      matching: find.byType(EditableText),
    )
    .first;

/// The code box of the only solution group. The editor's line-number gutter is
/// a borderless [TextField] of its own and comes first in the tree, so the code
/// box is picked out by the controller behind it instead of by position.
Finder _codeField() => find
    .byWidgetPredicate(
      (widget) =>
          widget is EditableText && widget.controller is LeetCodeCodeController,
    )
    .first;

Finder _dialogButton(String label) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(label));

void main() {
  testWidgets('a new entry retracks from the latest submission', (
    tester,
  ) async {
    final repo = await _openModal(
      tester,
      api: _FakeLeetCodeApi(recent: _twoSum),
      username: 'juno',
    );

    await tester.enterText(_algorithmField(), 'Hash map of complements');
    await tester.pumpAndSettle();
    await _tapRetrack(tester);
    await _save(tester, 'Save');

    final saved = repo.saved.single;
    expect(saved.title, 'Two Sum');
    expect(saved.questionFrontendId, '1');
    expect(saved.questionId, '1');
    expect(saved.titleSlug, 'two-sum');
    expect(saved.difficulty, LeetCodeDifficulty.easy);
    expect(saved.tags, ['Array', 'Hash-Table']);
    expect(saved.description, _twoSum.description);
    expect(saved.examples, _twoSum.examples);
    // The one thing on the form the user wrote themselves.
    expect(saved.solutions.single.algorithm, 'Hash map of complements');
  });

  testWidgets('an empty solution takes the submission language', (tester) async {
    final repo = await _openModal(
      tester,
      api: _FakeLeetCodeApi(recent: _twoSum),
      username: 'juno',
    );

    await tester.enterText(_algorithmField(), 'Hash map of complements');
    await tester.pumpAndSettle();
    await _tapRetrack(tester);
    await _save(tester, 'Save');

    expect(repo.saved.single.solutions.single.codeLanguage, 'cpp');
  });

  testWidgets('a solution with code in it keeps the language it was written '
      'in', (tester) async {
    final repo = await _openModal(
      tester,
      api: _FakeLeetCodeApi(recent: _twoSum),
      username: 'juno',
    );

    await tester.enterText(_codeField(), 'def two_sum(): pass');
    await tester.pumpAndSettle();
    await _tapRetrack(tester);
    await _save(tester, 'Save');

    // The submission was C++; this group was not, and the user said so by
    // typing in it.
    expect(repo.saved.single.solutions.single.codeLanguage, 'python');
  });

  testWidgets('an edit retracks by the name in the field, keeping that name', (
    tester,
  ) async {
    final api = _FakeLeetCodeApi(searchHit: _twoSumBySearch);
    final repo = await _openModal(tester, api: api, existing: _stale());

    await _tapRetrack(tester);
    await _save(tester, 'Save changes');

    expect(api.searchedFor, ['Two Sum']);
    final saved = repo.saved.single;
    expect(saved.title, 'Two Sum');
    expect(saved.questionFrontendId, '1');
    expect(saved.titleSlug, 'two-sum');
    expect(saved.difficulty, LeetCodeDifficulty.easy);
    expect(saved.tags, ['Array', 'Hash-Table']);
    expect(saved.description, _twoSum.description);
    expect(saved.examples, _twoSum.examples);
    // Everything the user wrote, plus the review history behind it.
    expect(saved.solutions.single.algorithm, 'Hash map of complements');
    expect(saved.solutions.single.code, 'hashed()');
    expect(saved.solutions.single.notes, 'open with this');
    // No submission behind a title lookup, so nothing to relanguage.
    expect(saved.solutions.single.codeLanguage, 'java');
    expect(saved.interval, 6);
    expect(saved.reviewCount, 3);
  });

  testWidgets('a hit under another name has to be confirmed first', (
    tester,
  ) async {
    final repo = await _openModal(
      tester,
      api: _FakeLeetCodeApi(searchHit: _twoSumBySearch),
      existing: _stale(title: 'Twoo Summ'),
    );

    await _tapRetrack(tester);

    expect(_dialogButton('Retrack'), findsOneWidget);
    await tester.tap(_dialogButton('Cancel'));
    await tester.pumpAndSettle();
    await _save(tester, 'Save changes');

    // Declining leaves the record exactly as it was — including the name that
    // found nothing.
    final saved = repo.saved.single;
    expect(saved.title, 'Twoo Summ');
    expect(saved.questionFrontendId, '999');
    expect(saved.difficulty, LeetCodeDifficulty.hard);
    expect(saved.tags, ['stale-tag']);
    expect(saved.description, 'A statement typed from memory.');
  });

  testWidgets('confirming a differently-named hit still keeps the typed name', (
    tester,
  ) async {
    final repo = await _openModal(
      tester,
      api: _FakeLeetCodeApi(searchHit: _twoSumBySearch),
      existing: _stale(title: 'Twoo Summ'),
    );

    await _tapRetrack(tester);
    await tester.tap(_dialogButton('Retrack'));
    await tester.pumpAndSettle();
    await _save(tester, 'Save changes');

    final saved = repo.saved.single;
    expect(saved.title, 'Twoo Summ');
    expect(saved.questionFrontendId, '1');
    expect(saved.difficulty, LeetCodeDifficulty.easy);
    expect(saved.tags, ['Array', 'Hash-Table']);
    expect(saved.description, _twoSum.description);
  });
}

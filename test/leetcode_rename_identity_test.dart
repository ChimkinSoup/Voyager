// A tracked problem's identity is its LeetCode slug when it has one, so the
// slug the Track flow prefilled has to stop describing the record the moment
// the user types a different problem's name over it — otherwise a freshly
// typed question is filed as the same question as whatever the form was
// prefilled from, and the two show up as duplicates of each other.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_track_draft_store.dart';
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

const _twoSum = LeetCodeApiQuestion(
  questionId: '1',
  questionFrontendId: '1',
  title: 'Two Sum',
  titleSlug: 'two-sum',
  difficulty: LeetCodeDifficulty.easy,
  topicTags: ['Array'],
  description: 'Return indices of the two numbers that add up to target.',
  examples: ['Input: nums = [2,7,11,15], target = 9\nOutput: [0,1]'],
);

/// Opens the Track modal already prefilled, the way the Track button leaves it
/// once the user's latest accepted submission has come back.
Future<_RecordingLeetCodeRepository> _openModal(
  WidgetTester tester, {
  LeetCodeApiQuestion? prefill,
  LeetCodeProblem? existing,
}) async {
  // Tall enough that the form needs no scrolling, so nothing parks under the
  // pinned close button — same reason the other track-modal tests do it.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = _RecordingLeetCodeRepository();
  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        leetCodeRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        leetCodeTrackDraftStoreProvider.overrideWithValue(
          MemoryLeetCodeTrackDraftStore(),
        ),
        settingsRepositoryProvider.overrideWithValue(
          _StubSettingsRepository(const AppSettings()),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              // Warm the settings the same way the real shell does.
              ref.watch(settingsProvider);
              return TextButton(
                onPressed: () => showLeetCodeTrackModal(
                  context,
                  ref,
                  prefill: prefill,
                  existing: existing,
                ),
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

/// The problem-name box. [VoyagerTextField] paints its label in the border
/// rather than mounting a `Text`, so the field is found by what is in it.
Finder _titleField(String current) => find.text(current);

Future<void> _save(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a prefilled entry renamed to another problem drops the slug', (
    tester,
  ) async {
    final repo = await _openModal(tester, prefill: _twoSum);

    await tester.enterText(_titleField('Two Sum'), 'Three Sum');
    await tester.pumpAndSettle();
    await _save(tester, 'Save');

    final saved = repo.saved.single;
    expect(saved.title, 'Three Sum');
    expect(saved.titleSlug, isNull);
    // Which is the whole point: it no longer shares an identity with the
    // already-tracked question the form was prefilled from.
    expect(leetCodeIdentityKey(saved), 'three-sum');
    expect(
      leetCodeIdentityKey(saved),
      isNot(
        leetCodeIdentityKey(
          LeetCodeProblem(
            id: 'other',
            createdAt: saved.createdAt,
            updatedAt: saved.createdAt,
            title: 'Two Sum',
            titleSlug: 'two-sum',
            difficulty: LeetCodeDifficulty.easy,
            solvedAt: saved.createdAt,
          ),
        ),
      ),
    );
  });

  testWidgets('a prefilled entry saved under its own name keeps the slug', (
    tester,
  ) async {
    final repo = await _openModal(tester, prefill: _twoSum);

    await _save(tester, 'Save');

    expect(repo.saved.single.titleSlug, 'two-sum');
  });

  testWidgets('typing the prefilled name back brings the slug back', (
    tester,
  ) async {
    final repo = await _openModal(tester, prefill: _twoSum);

    await tester.enterText(_titleField('Two Sum'), 'Three Sum');
    await tester.pumpAndSettle();
    await tester.enterText(_titleField('Three Sum'), 'Two Sum');
    await tester.pumpAndSettle();
    await _save(tester, 'Save');

    expect(repo.saved.single.titleSlug, 'two-sum');
  });

  testWidgets('renaming a saved problem drops its slug too', (tester) async {
    final now = DateTime.utc(2026, 8, 14, 9);
    final repo = await _openModal(
      tester,
      existing: LeetCodeProblem(
        id: 'p1',
        createdAt: now,
        updatedAt: now,
        title: 'Two Sum',
        titleSlug: 'two-sum',
        difficulty: LeetCodeDifficulty.easy,
        solvedAt: now,
      ),
    );

    await tester.enterText(_titleField('Two Sum'), 'Three Sum');
    await tester.pumpAndSettle();
    await _save(tester, 'Save changes');

    expect(repo.saved.single.titleSlug, isNull);
  });
}

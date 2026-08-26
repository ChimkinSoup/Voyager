// Regressions for the LeetCode page audit (LC-01 … LC-12). Each test pins the
// specific failure the fix closes rather than the surrounding feature, which
// the feature's own suite already covers — so a fix that gets reverted or
// re-broken by a refactor fails here by name.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/leetcode_api_client.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_loading_toast.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

final _now = DateTime.utc(2026, 8, 20, 9);

LeetCodeProblem _problem({
  String id = 'p1',
  String title = 'Two Sum',
  String algorithm = 'Hash map of complements',
  int version = 0,
  double interval = 0,
  int reviewCount = 0,
  DateTime? dueAt,
  DateTime? deletedAt,
}) => LeetCodeProblem(
  id: id,
  createdAt: _now,
  updatedAt: _now,
  version: version,
  deletedAt: deletedAt,
  title: title,
  questionFrontendId: '1',
  difficulty: LeetCodeDifficulty.easy,
  description: 'Return indices of the two numbers adding up to target.',
  solutions: [LeetCodeSolution(algorithm: algorithm)],
  solvedAt: _now,
  interval: interval,
  dueAt: dueAt,
  reviewCount: reviewCount,
);

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  noSuchMethod(Invocation invocation) => null;
}

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

/// A settings repository whose write is held open for as long as the test
/// needs, so two menu taps can land inside one round-trip.
///
/// Deliberately a *repository* stub rather than a [SettingsNotifier] subclass:
/// the bug and its fix both live in the notifier's own ordering, so a fake
/// that overrode `saveSettings` would encode the fix and test nothing.
class _SlowSettingsRepository implements SettingsRepository {
  final saved = <AppSettings>[];
  Completer<void>? gate;

  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async {
    saved.add(settings);
    await gate?.future;
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

Future<void> _pumpDeck(
  WidgetTester tester,
  List<LeetCodeProblem> problems, {
  List<Override> overrides = const [],
}) async {
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
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        ...overrides,
      ],
      child: const MaterialApp(
        home: Scaffold(body: SafeArea(child: LeetCodeReviewDeck())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Finder get _searchField => find.byType(TextField).first;

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(_searchField, query);
  await tester.pump();
}

/// The repository as the modal sees it: a library that can move underneath an
/// open sheet, and a write that can refuse.
class _MutableLeetCodeRepository implements LeetCodeRepository {
  _MutableLeetCodeRepository(this.problems);

  final Map<String, LeetCodeProblem> problems;
  final saved = <LeetCodeProblem>[];
  bool failWrites = false;

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => problems.values.toList();

  @override
  Future<LeetCodeProblem?> getProblem(String id) async => problems[id];

  @override
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  }) async {
    if (failWrites) throw Exception('database is locked');
    saved.add(problem);
    problems[problem.id] = problem;
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

Future<void> _openEditModal(
  WidgetTester tester,
  _MutableLeetCodeRepository repo,
  LeetCodeProblem existing,
) async {
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
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
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
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save changes'));
  await tester.tap(find.text('Save changes'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'LC-01 the flashcard survives reduced motion, which mounts both faces',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              _StubSettingsRepository(),
            ),
          ],
          child: MaterialApp(
            home: MediaQuery(
              // The reduced-motion branch of StudyFlipCard crossfades rather
              // than rotating, so front *and* back are in the tree at once. A
              // single GlobalKey shared between the faces threw here.
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 700,
                    height: 1200,
                    child: LeetCodeFlashcard(problem: _problem()),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      // Both faces really are mounted — otherwise this test would pass for the
      // wrong reason on any future change that stops crossfading.
      expect(find.text('1 Two Sum'), findsNWidgets(2));
    },
  );

  testWidgets('LC-05 a toast dismissed before it builds still goes away', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    // Show and dismiss inside one frame gap — what a fetch that fails on a
    // host lookup does, in single-digit milliseconds. The overlay entry has
    // not built yet, so there is no State to hear the dismiss notifier.
    final dismiss = showLeetCodeToast(ctx, message: 'Fetching…');
    dismiss();

    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Fetching…'), findsNothing);
    // The orphaned spinner used to animate forever, so settling is the second
    // signal that the entry is genuinely gone rather than merely invisible.
    await tester.pumpAndSettle();
  });

  test('LC-06 a stalled request throws on the deadline instead of hanging', () {
    fakeAsync((async) {
      final client = LeetCodeApiClient(
        httpClient: _StallingClient(),
        timeout: const Duration(seconds: 2),
      );
      Object? thrown;
      unawaited(
        client.fetchQuestionCounts().then<void>(
          (_) {},
          onError: (Object e) => thrown = e,
        ),
      );

      async.elapse(const Duration(seconds: 1));
      expect(thrown, isNull, reason: 'still inside the deadline');

      async.elapse(const Duration(seconds: 2));
      expect(thrown, isA<Exception>());
      expect('$thrown', contains('timed out'));
    });
  });

  test('LC-08 a soft delete bumps the version like every other mutation', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftLeetCodeRepository(db);

    await repo.upsertProblem(_problem(version: 5));
    await repo.softDeleteProblem('p1');

    final deleted = await repo.getProblem('p1');
    expect(deleted!.deletedAt, isNotNull);
    // A tombstone left at version 5 could only win on a wall-clock comparison
    // between two devices; version is what the conflict resolver checks first.
    expect(deleted.version, 6);
  });

  test('LC-08 deleting a row that is already gone is a no-op, not a throw',
      () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftLeetCodeRepository(db);

    await repo.softDeleteProblem('never-existed');

    expect(await repo.getProblem('never-existed'), isNull);
  });

  testWidgets('LC-07 "Clear filters" empties the search box, not just the grid',
      (tester) async {
    await _pumpDeck(tester, [_problem()]);
    await _search(tester, 'zzzznomatch');

    await tester.tap(
      find.ancestor(
        of: find.text('Clear filters'),
        matching: find.byType(GlassButton),
      ),
    );
    await tester.pump();

    // The grid un-filters either way. What used to stay behind was the query
    // in the box, so the user's next keystroke appended to invisible-but-live
    // stale text and the grid snapped back to "No matches" on one character.
    // Read what the field is actually displaying — an uncontrolled TextField
    // has no controller of its own to inspect, but it still shows the query.
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller
          .text,
      '',
    );
    expect(find.byType(LeetCodeMiniFlashcard), findsOneWidget);
  });

  testWidgets('LC-07 typing after a clear filters on the new query alone', (
    tester,
  ) async {
    await _pumpDeck(tester, [_problem(title: 'Two Sum')]);
    await _search(tester, 'zzzznomatch');
    await tester.tap(
      find.ancestor(
        of: find.text('Clear filters'),
        matching: find.byType(GlassButton),
      ),
    );
    await tester.pump();

    await _search(tester, 'two');
    expect(find.byType(LeetCodeMiniFlashcard), findsOneWidget);
  });

  testWidgets(
    'LC-11 a hand-flipped tile stays on its back when the search starts '
    'matching only that back',
    (tester) async {
      await _pumpDeck(tester, [
        _problem(title: 'Two Sum', algorithm: 'Sliding window'),
      ]);

      // No query: the tile rests on its front. Turn it over by hand.
      expect(find.text('Two Sum'), findsOneWidget);
      await tester.tap(find.byType(LeetCodeMiniFlashcard));
      await tester.pumpAndSettle();
      expect(find.text('Sliding window'), findsOneWidget);

      // Now a query that matches only the back. The override was recorded
      // against the old baseline, so it retires rather than inverting the tile
      // to its front — the exact opposite of what a back-only match is for.
      await _search(tester, 'sliding');
      await tester.pumpAndSettle();
      expect(find.text('Sliding window'), findsOneWidget);

      // Clearing the query hands the manual flip back rather than dropping it.
      await _search(tester, '');
      await tester.pumpAndSettle();
      expect(find.text('Sliding window'), findsOneWidget);
    },
  );

  testWidgets('LC-09 two display-menu taps inside one write both stick', (
    tester,
  ) async {
    final settings = _SlowSettingsRepository()..gate = Completer<void>();

    await _pumpDeck(
      tester,
      [_problem()],
      overrides: [settingsRepositoryProvider.overrideWithValue(settings)],
    );

    await tester.tap(find.byTooltip('What Study and Cram show on the card'));
    await tester.pumpAndSettle();

    // Both taps land while the first write is still in flight, so each used to
    // compute its delta against the same pre-write settings and the second
    // silently undid the first.
    await tester.tap(find.text('Hide tags'));
    await tester.pump();
    await tester.tap(find.text('Hide solution code'));
    await tester.pump();

    settings.gate!.complete();
    await tester.pumpAndSettle();

    expect(settings.saved, hasLength(2));
    expect(settings.saved.last.leetCodeHideTags, isTrue);
    expect(settings.saved.last.leetCodeHideCode, isTrue);
  });

  testWidgets('LC-09 double-tapping one row lands on the value it shows', (
    tester,
  ) async {
    final settings = _SlowSettingsRepository()..gate = Completer<void>();

    await _pumpDeck(
      tester,
      [_problem()],
      overrides: [settingsRepositoryProvider.overrideWithValue(settings)],
    );

    await tester.tap(find.byTooltip('What Study and Cram show on the card'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hide tags'));
    await tester.pump();
    await tester.tap(find.text('Hide tags'));
    await tester.pump();

    settings.gate!.complete();
    await tester.pumpAndSettle();

    // On and straight back off — the second tap used to recompute the same
    // `true` off the same stale snapshot and appear to do nothing at all.
    expect(settings.saved.map((s) => s.leetCodeHideTags), [true, false]);
  });

  testWidgets('LC-09 two taps inside one frame compose too', (tester) async {
    final settings = _SlowSettingsRepository()..gate = Completer<void>();

    await _pumpDeck(
      tester,
      [_problem()],
      overrides: [settingsRepositoryProvider.overrideWithValue(settings)],
    );

    await tester.tap(find.byTooltip('What Study and Cram show on the card'));
    await tester.pumpAndSettle();

    // No pump between them, so no rebuild can refresh the menu's build-time
    // capture. Publishing early is not enough here — the row has to read the
    // notifier's value at tap time for the second delta to see the first.
    await tester.tap(find.text('Hide tags'), warnIfMissed: false);
    await tester.tap(find.text('Hide solution code'), warnIfMissed: false);
    await tester.pump();

    settings.gate!.complete();
    await tester.pumpAndSettle();

    expect(settings.saved.last.leetCodeHideTags, isTrue);
    expect(settings.saved.last.leetCodeHideCode, isTrue);
  });

  testWidgets('LC-04 an edit rebases onto the live row, not the captured one', (
    tester,
  ) async {
    final opened = _problem(version: 3, interval: 1, reviewCount: 1);
    final repo = _MutableLeetCodeRepository({opened.id: opened});
    await _openEditModal(tester, repo, opened);

    // A sync tick lands another device's grade underneath the open sheet.
    repo.problems[opened.id] = _problem(
      version: 9,
      interval: 21,
      reviewCount: 6,
      dueAt: DateTime.utc(2026, 9, 30),
    );

    await _tapSave(tester);

    final written = repo.saved.single;
    // The schedule belongs to the deck, so it comes off the live row. Saving
    // the captured snapshot rolled it back to where it stood minutes ago…
    expect(written.interval, 21);
    expect(written.reviewCount, 6);
    expect(written.dueAt, DateTime.utc(2026, 9, 30));
    // …and wrote 4 for the version, which is *behind* the row it overwrote —
    // so the next pull would rank the remote copy above this very edit.
    expect(written.version, 10);
  });

  testWidgets('LC-04 an edit does not resurrect a problem deleted underneath it',
      (tester) async {
    final opened = _problem(version: 3);
    final repo = _MutableLeetCodeRepository({opened.id: opened});
    await _openEditModal(tester, repo, opened);

    repo.problems[opened.id] = _problem(
      version: 4,
      deletedAt: DateTime.utc(2026, 8, 25),
    );

    await _tapSave(tester);

    // The constructor used to omit deletedAt entirely, and the upsert writes
    // every column — so the tombstone was cleared by a save that never meant
    // to touch it.
    expect(repo.saved.single.deletedAt, DateTime.utc(2026, 8, 25));
  });

  testWidgets('LC-03 a failed save leaves the Save button pressable', (
    tester,
  ) async {
    final opened = _problem();
    final repo = _MutableLeetCodeRepository({opened.id: opened})
      ..failWrites = true;
    await _openEditModal(tester, repo, opened);

    await _tapSave(tester);

    // The sheet is still up — an edit has no draft behind it, so popping here
    // would take the user's changes with it.
    expect(find.text('Save changes'), findsOneWidget);
    expect(repo.saved, isEmpty);
    // And it says so, rather than the button simply going dead.
    expect(find.textContaining("Couldn't save"), findsOneWidget);

    // The latch came off: a retry that succeeds still commits.
    repo.failWrites = false;
    await _tapSave(tester);
    expect(repo.saved, hasLength(1));

    // Let the failure toast's own dismissal timer run out, so it isn't still
    // pending when the tree comes down.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  test('LC-10 a failed counts fetch expires, so a later read retries', () async {
    var attempts = 0;
    final container = ProviderContainer(
      overrides: [
        leetCodeApiClientProvider.overrideWithValue(
          _FlakyCountsApi(() {
            attempts++;
            if (attempts == 1) throw Exception('offline');
            return const LeetCodeQuestionCounts(easy: 1, medium: 2, hard: 3);
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    // A listener, the way the rings watch it — then it goes away, the way the
    // page does when the user navigates off it.
    var sub = container.listen(leetcodeQuestionCountsProvider, (_, __) {});
    await expectLater(
      container.read(leetcodeQuestionCountsProvider.future),
      throwsA(isA<Exception>()),
    );
    sub.close();
    await pumpEventQueue();

    // The error is not held: coming back re-runs the fetch. It used to be
    // cached for the life of the process, with nothing on screen saying the
    // fetch had failed and no control to retry.
    sub = container.listen(leetcodeQuestionCountsProvider, (_, __) {});
    final counts = await container.read(leetcodeQuestionCountsProvider.future);
    expect(counts.total, 6);
    expect(attempts, 2);

    // A success *is* held past its last listener — the counts move a handful
    // of times a week, so re-fetching on every visit would be waste.
    sub.close();
    await pumpEventQueue();
    container.listen(leetcodeQuestionCountsProvider, (_, __) {});
    expect(await container.read(leetcodeQuestionCountsProvider.future), counts);
    expect(attempts, 2);
  });

}

/// A client whose request never completes — a captive portal, a hung proxy, a
/// half-open socket. Without a deadline every caller waits on it forever.
class _StallingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// Counts that fail on demand, so a test can watch the provider recover.
class _FlakyCountsApi extends LeetCodeApiClient {
  _FlakyCountsApi(this.next);

  final LeetCodeQuestionCounts Function() next;

  @override
  Future<LeetCodeQuestionCounts> fetchQuestionCounts() async => next();
}

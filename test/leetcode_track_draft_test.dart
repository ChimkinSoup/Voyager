// The create-Track form keeps one local draft so closing the sheet doesn't cost
// the user their typing. Almost every assertion here is about *which* form came
// back — the draft, a fresh prefill, or nothing — and about the single slot on
// disk being left alone, overwritten, or cleared at exactly the right moments.
//
// Nothing in this feature syncs, so nothing here asserts against the repository
// except where a save is supposed to retire the draft.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/leetcode_api_client.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_track_draft.dart';
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

/// Sleeps a beat so the in-flight toast gets a frame to mount in — see the
/// same note in leetcode_retrack_test.dart.
class _FakeLeetCodeApi extends LeetCodeApiClient {
  _FakeLeetCodeApi({this.recent, this.fails = false, Duration? latency})
    : latency = latency ?? _defaultLatency;

  final LeetCodeApiQuestion? recent;
  final bool fails;
  final Duration latency;
  int fetches = 0;

  static const _defaultLatency = Duration(milliseconds: 20);

  @override
  Future<LeetCodeApiQuestion?> fetchMostRecentAcceptedSubmission(
    String username,
  ) async {
    fetches++;
    await Future<void>.delayed(latency);
    if (fails) throw Exception('offline');
    return recent;
  }
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
  submissionLanguage: 'cpp',
);

const _threeSum = LeetCodeApiQuestion(
  questionId: '15',
  questionFrontendId: '15',
  title: 'Three Sum',
  titleSlug: '3sum',
  difficulty: LeetCodeDifficulty.medium,
  topicTags: ['Array'],
  description: 'Find all triplets that sum to zero.',
  examples: ['Input: nums = [-1,0,1,2,-1,-4]'],
  submissionLanguage: 'python3',
);

/// A draft with one line of the user's own writing in it, so the "did the
/// draft come back" assertions have something unmistakable to look for.
LeetCodeTrackDraft _draftFor(
  String title, {
  String algorithm = 'two pointers after a sort',
  String description = '',
}) => LeetCodeTrackDraft(
  title: title,
  questionFrontendId: '15',
  tags: '',
  description: description,
  examples: const [],
  difficulty: LeetCodeDifficulty.medium,
  solutions: [
    LeetCodeTrackDraftSolution(codeLanguage: 'python', algorithm: algorithm),
  ],
  savedAt: DateTime.utc(2026, 8, 15),
);

/// Mounts the app shell the Track flow needs and returns the pieces a test
/// asserts against. Nothing opens until [_track] or [_openEdit] is called.
class _Harness {
  _Harness(this.store, this.repo, this.api);

  final MemoryLeetCodeTrackDraftStore store;
  final _RecordingLeetCodeRepository repo;
  final _FakeLeetCodeApi api;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required _FakeLeetCodeApi api,
  LeetCodeTrackDraft? draft,
  String? username = 'juno',
  LeetCodeProblem? editing,
}) async {
  // Tall enough that the form needs no scrolling, so no row parks under the
  // pinned close button — same reason the other track-modal tests do it.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = MemoryLeetCodeTrackDraftStore()..draft = draft;
  final repo = _RecordingLeetCodeRepository();
  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        leetCodeRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        leetCodeApiClientProvider.overrideWithValue(api),
        leetCodeTrackDraftStoreProvider.overrideWithValue(store),
        settingsRepositoryProvider.overrideWithValue(
          _StubSettingsRepository(AppSettings(leetcodeUsername: username)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              // Warm the settings the same way the real shell does.
              ref.watch(settingsProvider);
              return Column(
                children: [
                  TextButton(
                    onPressed: () => startLeetCodeTrackFlow(context, ref),
                    child: const Text('track'),
                  ),
                  TextButton(
                    onPressed: () =>
                        showLeetCodeTrackModal(context, ref, existing: editing),
                    child: const Text('edit'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(store, repo, api);
}

/// Runs the Track button through its fetch and lands on the open modal.
Future<void> _track(WidgetTester tester) async {
  await tester.tap(find.text('track'));
  // One frame to mount the in-flight toast, then long enough for the fake
  // lookup to land.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

Future<void> _openEdit(WidgetTester tester) async {
  await tester.tap(find.text('edit'));
  await tester.pumpAndSettle();
}

/// Closes the sheet through the pinned X, which is the path the close flush
/// hangs off.
Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close'));
  await tester.pumpAndSettle();
}

/// The problem-name box. [VoyagerTextField] paints `labelText` into its border
/// rather than mounting a `Text`, and this field has no hint to find it by —
/// but it is the first editor in the form.
Finder _titleField() => find.byType(EditableText).first;

/// The ID box, which sits beside the name and is likewise label-only.
Finder _idField() => find.byType(EditableText).at(1);

Finder _fieldByHint(String hint) => find
    .descendant(
      of: find
          .ancestor(of: find.text(hint), matching: find.byType(TextField))
          .first,
      matching: find.byType(EditableText),
    )
    .first;

Finder _algorithmField() => _fieldByHint('Core approach in a sentence or two');
Finder _descriptionField() =>
    _fieldByHint('Problem statement shown on the flashcard front');

String _textOf(WidgetTester tester, Finder finder) =>
    tester.widget<EditableText>(finder).controller.text;

Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

void main() {
  group('draft slot', () {
    testWidgets('a prefilled form closed untouched leaves the slot alone', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
      );

      await _track(tester);
      expect(_textOf(tester, _titleField()), 'Two Sum');
      await _close(tester);

      expect(harness.store.draft, isNull);
    });

    testWidgets('an untouched form does not disturb an existing draft', (
      tester,
    ) async {
      final existing = _draftFor('Three Sum');
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: existing,
      );

      await _track(tester);
      await _close(tester);

      expect(harness.store.draft, same(existing));
    });

    testWidgets('any change to the form persists the whole thing', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
      );

      await _track(tester);
      await _type(tester, _algorithmField(), 'hash map of complements');
      await _close(tester);

      final draft = harness.store.draft!;
      // Not just the box that was typed in: the full form, prefill included.
      expect(draft.title, 'Two Sum');
      expect(draft.questionFrontendId, '1');
      expect(draft.tags, '#Array');
      expect(draft.description, _twoSum.description);
      expect(draft.examples, _twoSum.examples);
      expect(draft.difficulty, LeetCodeDifficulty.easy);
      expect(draft.titleSlug, 'two-sum');
      expect(draft.questionId, '1');
      expect(draft.solutions.single.algorithm, 'hash map of complements');
      expect(draft.solutions.single.codeLanguage, 'cpp');
    });

    testWidgets('adding a blank row counts as starting the form', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
      );

      await _track(tester);
      await tester.tap(find.text('Add solution'));
      await tester.pumpAndSettle();
      await _close(tester);

      final draft = harness.store.draft!;
      expect(draft.solutions, hasLength(2));
      expect(draft.solutions.last.algorithm, '');
    });

    testWidgets('a difficulty change alone counts as starting the form', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
      );

      await _track(tester);
      await tester.tap(find.text('Hard'));
      await tester.pumpAndSettle();
      await _close(tester);

      expect(harness.store.draft!.difficulty, LeetCodeDifficulty.hard);
    });

    testWidgets('wiping every text box clears the slot instead of saving it', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      expect(_textOf(tester, _idField()), '15');
      await _type(tester, _titleField(), '');
      await _type(tester, _idField(), '');
      await _type(tester, _algorithmField(), '');
      // Structural leftovers the rule has to ignore.
      await tester.tap(find.text('Add solution'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hard'));
      await tester.pumpAndSettle();
      await _close(tester);

      expect(harness.store.draft, isNull);
    });

    testWidgets('text left anywhere still saves the whole snapshot', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      await _type(tester, _titleField(), '');
      await _close(tester);

      final draft = harness.store.draft!;
      expect(draft.title, '');
      expect(draft.solutions.single.algorithm, 'two pointers after a sort');
    });

    testWidgets('a lifecycle flush writes the draft without closing', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
      );

      await _track(tester);
      await _type(tester, _algorithmField(), 'hash map of complements');
      // What the shell runs when the window goes away under the app.
      await PendingFlushRegistry.instance.flushAll();

      expect(
        harness.store.draft!.solutions.single.algorithm,
        'hash map of complements',
      );
      await _close(tester);
    });

    testWidgets('a successful save retires the draft', (tester) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      await _type(tester, _algorithmField(), 'sort, then two pointers');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(harness.repo.saved, hasLength(1));
      expect(harness.store.draft, isNull);
    });

    testWidgets('an edit never reads or writes the slot', (tester) async {
      final now = DateTime.utc(2026, 8, 14);
      final existing = _draftFor('Three Sum');
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: existing,
        editing: LeetCodeProblem(
          id: 'p1',
          createdAt: now,
          updatedAt: now,
          title: 'Valid Anagram',
          difficulty: LeetCodeDifficulty.easy,
          solvedAt: now,
        ),
      );

      await _openEdit(tester);
      // The saved problem, not the draft — an edit is not a draft resume.
      expect(_textOf(tester, _titleField()), 'Valid Anagram');
      await _type(tester, _algorithmField(), 'count the letters');
      await _close(tester);

      expect(harness.store.draft, same(existing));
    });
  });

  group('open flow', () {
    testWidgets('a matching title opens the draft with a resumed toast', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);

      // The lookup runs whether or not a draft is waiting.
      expect(harness.api.fetches, 1);
      expect(_textOf(tester, _algorithmField()), 'two pointers after a sort');
      expect(find.text('Picked up your draft'), findsOneWidget);
      // The draft's own blank description, not the API's statement.
      expect(_textOf(tester, _descriptionField()), '');

      await _close(tester);
    });

    testWidgets('the match ignores case and surrounding space', (tester) async {
      await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('  three sum '),
      );

      await _track(tester);

      expect(find.text('Picked up your draft'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a different title opens the prefill and offers the draft', (
      tester,
    ) async {
      final existing = _draftFor('Three Sum');
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: existing,
      );

      await _track(tester);

      expect(_textOf(tester, _titleField()), 'Two Sum');
      expect(find.text('Draft saved for "Three Sum"'), findsOneWidget);

      // Ignoring the offer leaves the draft where it was.
      await _close(tester);
      expect(harness.store.draft, same(existing));
    });

    testWidgets('Continue with draft swaps the form over, slot untouched', (
      tester,
    ) async {
      final existing = _draftFor('Three Sum');
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: existing,
      );

      await _track(tester);
      await tester.tap(find.text('Continue with draft'));
      await tester.pumpAndSettle();

      expect(_textOf(tester, _titleField()), 'Three Sum');
      expect(_textOf(tester, _algorithmField()), 'two pointers after a sort');
      // The offer toast is replaced by the resumed one.
      expect(find.text('Draft saved for "Three Sum"'), findsNothing);
      expect(find.text('Picked up your draft'), findsOneWidget);

      await _close(tester);
      expect(harness.store.draft, same(existing));
    });

    testWidgets('Clear draft empties the slot and refills from a new fetch', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      await tester.tap(find.text('Clear draft'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(harness.store.draft, isNull);
      // A second lookup, and a form built from it rather than from the draft.
      expect(harness.api.fetches, 2);
      expect(_textOf(tester, _titleField()), 'Three Sum');
      expect(_textOf(tester, _algorithmField()), '');
      expect(_textOf(tester, _descriptionField()), _threeSum.description);

      // Nothing has been touched since the refill, so nothing is written back.
      await _close(tester);
      expect(harness.store.draft, isNull);
    });

    testWidgets(
      'a keystroke during the Clear-draft refetch does not resurrect it',
      (tester) async {
        // Slower than the 400ms draft debounce, so a keystroke fired right
        // after "Clear draft" lands well before the refetch resolves.
        final api = _FakeLeetCodeApi(
          recent: _threeSum,
          latency: const Duration(milliseconds: 800),
        );
        final harness = await _pump(
          tester,
          api: api,
          draft: _draftFor('Three Sum'),
        );

        await _track(tester);
        await tester.tap(find.text('Clear draft'));
        await tester.pump();

        // The slot clears synchronously, before the refetch even lands.
        expect(harness.store.draft, isNull);

        // The old draft's controllers are still the ones on screen while the
        // refetch is in flight — typing into them must not autosave.
        await tester.enterText(_titleField(), 'stray edit');
        await tester.pump(const Duration(milliseconds: 450));
        expect(harness.store.draft, isNull);

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(_textOf(tester, _titleField()), 'Three Sum');
        expect(harness.store.draft, isNull);

        // Closing with no further edits must not leave anything behind.
        await _close(tester);
        expect(harness.store.draft, isNull);
      },
    );

    testWidgets('a failed fetch falls back to the draft', (tester) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(fails: true),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);

      expect(harness.api.fetches, 1);
      expect(_textOf(tester, _titleField()), 'Three Sum');
      expect(
        find.text("Couldn't refresh — showing your draft"),
        findsOneWidget,
      );

      await _close(tester);
    });

    testWidgets('no username with a draft still opens the draft', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: _draftFor('Three Sum'),
        username: null,
      );

      await _track(tester);

      expect(harness.api.fetches, 0);
      expect(_textOf(tester, _titleField()), 'Three Sum');
      expect(
        find.text("Couldn't refresh — showing your draft"),
        findsOneWidget,
      );

      await _close(tester);
    });

    testWidgets('no draft opens the prefill silently', (tester) async {
      await _pump(tester, api: _FakeLeetCodeApi(recent: _twoSum));

      await _track(tester);

      expect(_textOf(tester, _titleField()), 'Two Sum');
      expect(find.text('Picked up your draft'), findsNothing);
      expect(find.textContaining('Draft saved for'), findsNothing);
    });

    testWidgets('a title typed into a draft is what later matches', (
      tester,
    ) async {
      // The product case: prefilled with Two Sum, renamed to Three Sum, typed
      // into, closed. Solving Three Sum later brings that work back.
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
      );
      await _track(tester);
      await _type(tester, _titleField(), 'Three Sum');
      await _type(tester, _algorithmField(), 'sort, then two pointers');
      await _close(tester);

      expect(harness.store.draft!.title, 'Three Sum');

      // Second visit, with Three Sum now the latest accepted submission.
      final second = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: harness.store.draft,
      );
      await _track(tester);

      expect(find.text('Picked up your draft'), findsOneWidget);
      expect(_textOf(tester, _algorithmField()), 'sort, then two pointers');
      await _close(tester);
      expect(second.store.draft!.title, 'Three Sum');
    });

    testWidgets('a started edit on a mismatched form overwrites the slot', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      await _type(tester, _algorithmField(), 'hash map of complements');
      await _close(tester);

      final draft = harness.store.draft!;
      expect(draft.title, 'Two Sum');
      expect(draft.solutions.single.algorithm, 'hash map of complements');
    });
  });

  group('draft toast', () {
    testWidgets('dismisses itself once its dwell is up', (tester) async {
      await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _threeSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      expect(find.text('Picked up your draft'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Picked up your draft'), findsNothing);

      await _close(tester);
    });

    testWidgets(
      'a hovered toast stays up, and lingers after the pointer goes',
      (tester) async {
        await _pump(
          tester,
          api: _FakeLeetCodeApi(recent: _threeSum),
          draft: _draftFor('Three Sum'),
        );

        await _track(tester);
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: Offset.zero);
        addTearDown(pointer.removePointer);
        await tester.pump();
        await pointer.moveTo(
          tester.getCenter(find.text('Picked up your draft')),
        );
        await tester.pumpAndSettle();

        // Well past the dwell, and still there because the pointer is on it.
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        expect(find.text('Picked up your draft'), findsOneWidget);

        await pointer.moveTo(const Offset(5, 5));
        await tester.pump();

        // The linger is generous on purpose: a toast the user was reading a
        // moment ago doesn't vanish the instant the pointer slips off it.
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('Picked up your draft'), findsOneWidget);

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('Picked up your draft'), findsNothing);

        await _close(tester);
      },
    );

    testWidgets('a toast raised by a toast action gets its own full dwell', (
      tester,
    ) async {
      await _pump(
        tester,
        api: _FakeLeetCodeApi(recent: _twoSum),
        draft: _draftFor('Three Sum'),
      );

      await _track(tester);
      await tester.tap(find.text('Continue with draft'));
      await tester.pumpAndSettle();
      expect(find.text('Picked up your draft'), findsOneWidget);

      // Still up well after the offer toast it replaced would have expired …
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Picked up your draft'), findsOneWidget);

      // … and gone on its own schedule.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Picked up your draft'), findsNothing);

      await _close(tester);
    });
  });

  group('file store', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('voyager_draft_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    FileLeetCodeTrackDraftStore store() =>
        FileLeetCodeTrackDraftStore(directory: () async => dir);

    File slot() => File('${dir.path}/leetcode_track_draft.json');

    test('round-trips every field', () async {
      final draft = _draftFor('Three Sum', description: 'find the triplets');
      await store().save(draft);

      final loaded = (await store().load())!;
      expect(loaded.sameContentAs(draft), isTrue);
      expect(loaded.savedAt, draft.savedAt);
    });

    test('an empty slot reads as no draft', () async {
      expect(await store().load(), isNull);
    });

    test('a corrupt blob is discarded, not thrown', () async {
      await slot().writeAsString('{not json at all');

      expect(await store().load(), isNull);
      // Deleted rather than left to fail every future open.
      await Future<void>.delayed(Duration.zero);
      expect(await slot().exists(), isFalse);
    });

    test('a blob from another schema version is discarded', () async {
      final blob = _draftFor('Three Sum').toJson()..['version'] = 99;
      await slot().writeAsString(jsonEncode(blob));

      expect(await store().load(), isNull);
    });

    test('clear removes the slot', () async {
      await store().save(_draftFor('Three Sum'));
      await store().clear();

      expect(await slot().exists(), isFalse);
      expect(await store().load(), isNull);
    });
  });
}

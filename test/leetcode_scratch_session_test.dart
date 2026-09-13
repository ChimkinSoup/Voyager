// The scratch pad is a surface added to a running Study or Cram session, so
// what matters is how it behaves *against* the session: one pad per problem
// that survives an advance and an undo, a card that cannot be graded while the
// user is typing into it, and a session that leaves nothing behind on the way
// out.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_cram_page.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft_store.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';
import 'package:voyager/features/leetcode/leetcode_session_page.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_grading_row.dart';

import 'fakes/input_order_random.dart';

class _StubLeetCodeRepository implements LeetCodeRepository {
  _StubLeetCodeRepository(this.problems);

  List<LeetCodeProblem> problems;

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => problems;

  @override
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  }) async {
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

LeetCodeProblem _problem({
  required String id,
  required String title,
  List<LeetCodeSolution> solutions = const [],
}) {
  final now = DateTime.utc(2026, 8, 9, 12);
  return LeetCodeProblem(
    id: id,
    createdAt: now,
    updatedAt: now,
    title: title,
    questionFrontendId: id,
    difficulty: LeetCodeDifficulty.medium,
    solutions: solutions,
    solvedAt: now,
  );
}

/// Publishes [settings] as the app's settings row. The pad is created off
/// `leetCodeEnableScratchCode`, and nothing in a widget test warms
/// [settingsProvider] on its own.
class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

Future<MemoryLeetCodeScratchDraftStore> _pumpSession(
  WidgetTester tester,
  List<LeetCodeProblem> problems,
  Widget page, {
  bool scratchEnabled = true,
  MemoryLeetCodeScratchDraftStore? store,
}) async {
  // Wide enough to stay in the side-by-side layout rather than the narrow
  // stack, and tall enough that nothing the session shows is off screen.
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final scratchStore = store ?? MemoryLeetCodeScratchDraftStore();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        leetCodeRepositoryProvider.overrideWithValue(
          _StubLeetCodeRepository(problems),
        ),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        leetCodeScratchDraftStoreProvider.overrideWithValue(scratchStore),
        settingsProvider.overrideWith(
          () => _FixedSettings(
            AppSettings(leetCodeEnableScratchCode: scratchEnabled),
          ),
        ),
        noSessionShuffle,
      ],
      child: MaterialApp(home: page),
    ),
  );
  // Settings and problems both arrive asynchronously, and the pad is only
  // created once settings resolve.
  await tester.pump();
  await tester.pump();
  return scratchStore;
}

Finder get _pad => find.byType(LeetCodeScratchPad);

/// Turns the card over, which is what arms the grading buttons. Taps its
/// upper-left corner rather than its middle: the centred title is its own tap
/// target, and hitting that opens the detail view instead of flipping.
Future<void> _reveal(WidgetTester tester) async {
  final card = tester.getRect(find.byType(StudyFlipCard).first);
  await tester.tapAt(card.topLeft + const Offset(40, 40));
  await tester.pumpAndSettle();
}

/// Puts the caret in the pad the way clicking into it does. The editor is the
/// one part of the pad that takes a tap without expanding it — and it is the
/// *last* field in the box, since the line-number column is a field of its own
/// that sits to its left and refuses focus.
Future<void> _focusPad(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: _pad, matching: find.byType(EditableText)).last,
  );
  await tester.pump();
}

void main() {
  final twoSum = _problem(
    id: '1',
    title: 'Two Sum',
    solutions: const [
      LeetCodeSolution(
        code: 'class Solution:\n    def twoSum(self, nums, target):\n'
            '        return []',
        codeLanguage: 'python',
      ),
    ],
  );
  final addTwo = _problem(id: '2', title: 'Add Two Numbers');

  group('the setting decides whether there is a pad at all', () {
    testWidgets('off leaves the session exactly as it was', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
        scratchEnabled: false,
      );
      expect(_pad, findsNothing);
    });

    testWidgets('on puts a pad beside the card in Study', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      expect(_pad, findsOneWidget);
    });

    testWidgets('on puts a pad beside the card in Cram', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeCramPage(problemIds: {'1'}),
      );
      expect(_pad, findsOneWidget);
    });
  });

  group('starter template', () {
    testWidgets('opens on the signature of the saved solution', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      final pad = tester.widget<LeetCodeScratchPad>(_pad);
      expect(pad.entry.language, 'python');
      expect(pad.controller.fullText, contains('def twoSum(self, nums, target)'));
      // The shape, never the answer.
      expect(pad.controller.fullText, contains('pass'));
      expect(pad.controller.fullText, isNot(contains('return []')));
    });

    testWidgets('a problem with no solution gets the language default', (
      tester,
    ) async {
      await _pumpSession(
        tester,
        [addTwo],
        const LeetCodeSessionPage(problemIds: {'2'}),
      );
      final pad = tester.widget<LeetCodeScratchPad>(_pad);
      expect(pad.entry.language, 'python');
      expect(pad.controller.fullText, contains('class Solution:'));
    });

    testWidgets('the pad is tokenized in the language it opens in', (
      tester,
    ) async {
      // A CodeController with no grammar highlights nothing, which is what
      // the pad did while the Track modal's box — which sets one in its own
      // initState — highlighted normally.
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      final pad = tester.widget<LeetCodeScratchPad>(_pad);
      expect(pad.controller.language, leetCodeHighlightMode('python'));
    });
  });

  group('one pad per problem', () {
    testWidgets('advancing brings up a different pad, and undo brings the '
        'first one back with what was typed in it', (tester) async {
      await _pumpSession(
        tester,
        [twoSum, addTwo],
        const LeetCodeSessionPage(problemIds: {'1', '2'}),
      );

      final first = tester.widget<LeetCodeScratchPad>(_pad);
      expect(first.problem.id, '1');
      first.controller.fullText = 'my attempt at two sum';
      await tester.pump();

      // Reveal the answer, then grade — the only way a session advances.
      await _reveal(tester);
      final row = tester.widget<StudyGradingRow>(find.byType(StudyGradingRow));
      row.onGrade(StudyGrade.good);
      await tester.pump();
      await tester.pump();

      final second = tester.widget<LeetCodeScratchPad>(_pad);
      expect(second.problem.id, '2');
      expect(second.controller.fullText, isNot('my attempt at two sum'));

      // Step back: the pad that comes with the card is the one it had.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.pump();
      await tester.pump();

      final back = tester.widget<LeetCodeScratchPad>(_pad);
      expect(back.problem.id, '1');
      expect(back.controller.fullText, 'my attempt at two sum');
    });
  });

  group('the pad and the session compete for the same keys', () {
    testWidgets('typing in the pad does not grade the card', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      await _reveal(tester);
      await _focusPad(tester);

      // G is the default Good binding. With the caret in the editor it is a
      // character, not a grade.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();

      // Still the same card: nothing was graded out from under the typing.
      expect(
        tester.widget<LeetCodeScratchPad>(_pad).problem.id,
        '1',
      );
    });

    testWidgets('the grading row dims while the pad has the caret', (
      tester,
    ) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      await _reveal(tester);
      expect(
        tester.widget<StudyGradingRow>(find.byType(StudyGradingRow)).enabled,
        isTrue,
      );

      await _focusPad(tester);

      expect(
        tester.widget<StudyGradingRow>(find.byType(StudyGradingRow)).enabled,
        isFalse,
      );
    });
  });

  group('the recovery file', () {
    testWidgets('a session that ends normally leaves nothing behind', (
      tester,
    ) async {
      final store = await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );

      tester.widget<LeetCodeScratchPad>(_pad).controller.fullText = 'typed';
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.session, isNotNull);

      // Leaving the session is what deletes it — the file only survives a run
      // that never got to dispose.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(store.session, isNull);
    });

    testWidgets('an orphan is offered back, not silently loaded', (
      tester,
    ) async {
      final store = MemoryLeetCodeScratchDraftStore()
        ..session = LeetCodeScratchSession(
          sessionId: 'previous',
          problemIds: const {'1'},
          startedAt: DateTime.utc(2026, 8, 30),
          scratches: const {
            '1': LeetCodeScratchEntry(
              code: 'work from the run that died',
              language: 'python',
            ),
          },
        );

      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
        store: store,
      );
      await tester.pump();

      // The pad opens on its starter, not on the orphan.
      expect(
        tester.widget<LeetCodeScratchPad>(_pad).controller.fullText,
        isNot('work from the run that died'),
      );
      expect(find.text('Restore'), findsOneWidget);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<LeetCodeScratchPad>(_pad).controller.fullText,
        'work from the run that died',
      );
    });

    testWidgets('a run that died mid-edit comes back with the editor open', (
      tester,
    ) async {
      final store = MemoryLeetCodeScratchDraftStore()
        ..session = LeetCodeScratchSession(
          sessionId: 'previous',
          problemIds: const {'1'},
          startedAt: DateTime.utc(2026, 8, 30),
          scratches: const {
            '1': LeetCodeScratchEntry(
              code: 'half-written',
              language: 'python',
              expanded: true,
            ),
          },
        );

      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
        store: store,
      );
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.text('Compare'), findsOneWidget);
    });

    testWidgets('a clean previous session is never offered back', (
      tester,
    ) async {
      final store = MemoryLeetCodeScratchDraftStore()
        ..session = LeetCodeScratchSession(
          sessionId: 'previous',
          problemIds: const {'1'},
          startedAt: DateTime.utc(2026, 8, 30),
          endedNormally: true,
          scratches: const {
            '1': LeetCodeScratchEntry(code: 'old', language: 'python'),
          },
        );

      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
        store: store,
      );
      await tester.pump();

      expect(find.text('Restore'), findsNothing);
    });
  });

  group('the expanded editor', () {
    testWidgets('C opens it, and the scrim closes it again', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      expect(find.text('Compare'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(find.text('Compare'), findsOneWidget);

      // The panel stops short of the screen edge precisely so there is an
      // outside to click — Escape belongs to Vim.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Compare'), findsNothing);
    });

    testWidgets('C does not fire while the caret is already in the pad', (
      tester,
    ) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      await _focusPad(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();

      // It is a character being typed, not a shortcut.
      expect(find.text('Compare'), findsNothing);
    });

    testWidgets('grading is blocked while it is open', (tester) async {
      await _pumpSession(
        tester,
        [twoSum, addTwo],
        const LeetCodeSessionPage(problemIds: {'1', '2'}),
      );
      await _reveal(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();

      // G is the default Good binding. The editor is a route over the session,
      // so the session is not the one listening.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();
      expect(find.text('Compare'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(tester.widget<LeetCodeScratchPad>(_pad).problem.id, '1');
    });

    testWidgets('Copy puts what was typed on the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      tester.widget<LeetCodeScratchPad>(_pad).controller.fullText = 'my code';

      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copied, ['my code']);
    });

    testWidgets('Clear puts the starter back', (tester) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      final controller = tester.widget<LeetCodeScratchPad>(_pad).controller;
      final starter = controller.fullText;
      controller.fullText = 'scrapped this';

      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(controller.fullText, starter);
    });
  });

  group('compare', () {
    testWidgets('lines the scratch up against the saved solution', (
      tester,
    ) async {
      await _pumpSession(
        tester,
        [twoSum],
        const LeetCodeSessionPage(problemIds: {'1'}),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare'));
      await tester.pumpAndSettle();

      expect(find.byType(LeetCodeScratchCompare), findsOneWidget);
      expect(find.text('Your scratch'), findsOneWidget);
      expect(find.text('Saved solution'), findsOneWidget);
      // The saved line the starter dropped is on the solution side.
      expect(find.text('        return []'), findsOneWidget);
    });

    testWidgets('says so when the problem has no solution to compare with', (
      tester,
    ) async {
      await _pumpSession(
        tester,
        [addTwo],
        const LeetCodeSessionPage(problemIds: {'2'}),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare'));
      await tester.pumpAndSettle();

      expect(find.text('No saved solution'), findsOneWidget);
    });
  });
}

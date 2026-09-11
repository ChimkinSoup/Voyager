// Space in a running session only ever turns the card over. The session's
// shortcuts listen on HardwareKeyboard, and a key claimed there still reaches
// the focus tree afterwards: an arrow press also moved focus onto the header's
// × — the leftmost focusable widget — and the next Space pressed it, closing
// the session under the user. Tab got there the same way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/keyboard_focus_utils.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_cram_page.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft_store.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';
import 'package:voyager/features/leetcode/leetcode_session_page.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_session_page.dart';

const _deckId = 'focus-deck';

class _RecordingStudyRepository implements StudyRepository {
  _RecordingStudyRepository(this.cards);

  List<StudyCard> cards;

  @override
  Future<List<StudyCard>> getAllCards({bool includeDeleted = true}) async =>
      cards;

  @override
  Future<StudyCard?> getCard(String id) async =>
      cards.where((c) => c.id == id).firstOrNull;

  @override
  Future<void> upsertCard(
    StudyCard card, {
    bool recordLocalActivity = true,
  }) async {
    cards = [
      for (final c in cards)
        if (c.id == card.id) card else c,
    ];
  }

  @override
  Future<void> logReview(
    StudyReviewLog log, {
    bool recordLocalActivity = true,
  }) async {}

  @override
  Future<StudyReviewLog?> getReviewLog(String id) async => null;

  @override
  Future<void> softDeleteReviewLog(String id) async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubLeetCodeRepository implements LeetCodeRepository {
  _StubLeetCodeRepository(this.problems);

  final List<LeetCodeProblem> problems;

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => problems;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

/// The pad is created off `leetCodeEnableScratchCode`, and nothing in a widget
/// test warms [settingsProvider] on its own.
class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      const AppSettings(leetCodeEnableScratchCode: true);
}

List<StudyCard> _cards(int count) {
  final now = DateTime.utc(2026, 8, 9, 12);
  return [
    for (var i = 0; i < count; i++)
      StudyCard(
        id: 'card-$i',
        createdAt: now,
        updatedAt: now,
        deckId: _deckId,
        frontText: 'Front $i',
        backText: 'Back $i',
        dueAt: now,
      ),
  ];
}

List<LeetCodeProblem> _problems() {
  final now = DateTime.utc(2026, 8, 9, 12);
  return [
    for (final (id, title) in [('1', 'Two Sum'), ('2', 'Add Two Numbers')])
      LeetCodeProblem(
        id: id,
        createdAt: now,
        updatedAt: now,
        title: title,
        questionFrontendId: id,
        difficulty: LeetCodeDifficulty.medium,
        solutions: const [LeetCodeSolution(algorithm: 'An approach')],
        solvedAt: now,
      ),
  ];
}

List<Override> _studyOverrides() => [
  studyRepositoryProvider.overrideWithValue(_RecordingStudyRepository(_cards(3))),
  remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
];

List<Override> _leetCodeOverrides() => [
  leetCodeRepositoryProvider.overrideWithValue(
    _StubLeetCodeRepository(_problems()),
  ),
  remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
  leetCodeScratchDraftStoreProvider.overrideWithValue(
    MemoryLeetCodeScratchDraftStore(),
  ),
  settingsProvider.overrideWith(_FixedSettings.new),
];

/// Opens [page] the way the deck view does — pushed over it — so a session
/// that closes itself leaves the deck view showing rather than nothing.
Future<void> _open(
  WidgetTester tester,
  List<Override> overrides,
  Widget page,
) async {
  // Wide enough that a LeetCode session puts its pad beside the card.
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Deck view')),
      ),
    ),
  );
  unawaited(
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page)),
  );
  // Not pumpAndSettle: a cram card keeps a spring ticker alive, so settling
  // can outrun the timeout. This covers the route transition and the
  // providers resolving.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// The face Space should turn the on-screen study card to: its back if the
/// front is up, and the other way round.
String _otherFace() {
  for (var i = 0; i < 3; i++) {
    if (find.text('Front $i').evaluate().isNotEmpty) return 'Back $i';
    if (find.text('Back $i').evaluate().isNotEmpty) return 'Front $i';
  }
  throw StateError('no study card on screen');
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The session is still up and the keys went nowhere they should not have:
/// no header button and no text field is holding focus.
void _expectStillInSession(WidgetTester tester, Type page) {
  expect(find.byType(page), findsOneWidget, reason: 'Space closed the session');
  expect(find.text('Deck view'), findsNothing);
  final focus = FocusManager.instance.primaryFocus;
  expect(
    focus?.context?.findAncestorWidgetOfExactType<IconButton>(),
    isNull,
    reason: 'focus landed on a header button',
  );
  expect(
    isTextInputFocused(),
    isFalse,
    reason: 'focus landed in a text field, so Space would type, not flip',
  );
}

void main() {
  const keys = {
    'right arrow': LogicalKeyboardKey.arrowRight,
    'left arrow': LogicalKeyboardKey.arrowLeft,
    'Tab': LogicalKeyboardKey.tab,
  };

  for (final MapEntry(key: name, value: key) in keys.entries) {
    group('Space after the $name', () {
      testWidgets('turns the card in a study review', (tester) async {
        await _open(
          tester,
          _studyOverrides(),
          const StudySessionPage(cardIds: {'card-0', 'card-1', 'card-2'}),
        );
        expect(find.text('Front 0'), findsOneWidget);

        await _press(tester, LogicalKeyboardKey.space);
        await _press(tester, key);
        await _press(tester, LogicalKeyboardKey.space);

        _expectStillInSession(tester, StudySessionPage);
        // Space turned card 0 over and back; nothing else moved.
        expect(find.text('Front 0'), findsOneWidget);
      });

      testWidgets('turns the card in a study review after a grade', (
        tester,
      ) async {
        await _open(
          tester,
          _studyOverrides(),
          const StudySessionPage(cardIds: {'card-0', 'card-1', 'card-2'}),
        );

        await _press(tester, LogicalKeyboardKey.space);
        await tester.tap(find.text('Good'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Front 1'), findsOneWidget);

        await _press(tester, key);
        final turnedTo = _otherFace();
        await _press(tester, LogicalKeyboardKey.space);

        _expectStillInSession(tester, StudySessionPage);
        expect(
          find.text(turnedTo),
          findsOneWidget,
          reason: 'Space should turn over whichever card the key left showing',
        );
      });

      testWidgets('turns the card in a study cram', (tester) async {
        await _open(
          tester,
          _studyOverrides(),
          const StudyCramPage(deckId: _deckId),
        );
        expect(find.text('Front 0'), findsOneWidget);

        await _press(tester, LogicalKeyboardKey.space);
        await _press(tester, key);
        final turnedTo = _otherFace();
        await _press(tester, LogicalKeyboardKey.space);

        _expectStillInSession(tester, StudyCramPage);
        expect(find.text(turnedTo), findsOneWidget);
      });

      testWidgets('turns the card in a LeetCode review', (tester) async {
        await _open(
          tester,
          _leetCodeOverrides(),
          const LeetCodeSessionPage(problemIds: {'1', '2'}),
        );
        expect(find.byType(LeetCodeScratchPad), findsOneWidget);

        await _press(tester, LogicalKeyboardKey.space);
        await _press(tester, key);
        await _press(tester, LogicalKeyboardKey.space);

        _expectStillInSession(tester, LeetCodeSessionPage);
      });

      testWidgets('turns the card in a LeetCode cram', (tester) async {
        await _open(
          tester,
          _leetCodeOverrides(),
          const LeetCodeCramPage(problemIds: {'1', '2'}),
        );
        expect(find.byType(LeetCodeScratchPad), findsOneWidget);

        await _press(tester, LogicalKeyboardKey.space);
        await _press(tester, key);
        await _press(tester, LogicalKeyboardKey.space);

        _expectStillInSession(tester, LeetCodeCramPage);
      });
    });
  }
}

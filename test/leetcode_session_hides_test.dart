// What a Study or Cram session leaves off the card. The hides are settings,
// so the card reads them straight off [settingsProvider] — which is what lets
// one menu in the Review Deck govern both session types at once.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_providers.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';
import 'package:voyager/features/study/study_flip_card.dart';

const _solution = LeetCodeSolution(
  algorithm: 'Hash map of complements',
  timeComplexity: 'O(n)',
  spaceComplexity: 'O(1)',
  explanation: 'Look up t - nums[i] as you go',
  code: 'def hashed(nums): pass',
);

LeetCodeProblem _problem() {
  final now = DateTime.utc(2026, 8, 14, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    questionFrontendId: '1',
    difficulty: LeetCodeDifficulty.easy,
    description: 'Return indices of the two numbers adding up to target.',
    examples: const ['Input: nums = [2,7]\nOutput: [0,1]'],
    tags: const ['array'],
    solutions: const [_solution],
    solvedAt: now,
  );
}

/// Publishes [settings] as the app's settings row, the way the session's card
/// reads them at runtime.
class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

/// Records what the menu saves rather than writing it to disk, so a test can
/// see the settings the toggle actually produced.
class _RecordingSettings extends SettingsNotifier {
  static AppSettings? saved;

  @override
  Future<AppSettings> build() async => const AppSettings();

  @override
  Future<void> saveSettings(AppSettings settings) async {
    saved = settings;
    state = AsyncData(settings);
  }
}

/// Pumps the full-size session card under [settings], turning it over when
/// [back] — the two faces hide different parts.
Future<void> _pumpCard(
  WidgetTester tester,
  AppSettings settings, {
  bool back = false,
}) async {
  final flip = StudyFlipController();
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => _FixedSettings(settings)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 700,
              height: 1200,
              child: LeetCodeFlashcard(problem: _problem(), controller: flip),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (back) {
    flip.flip();
    await tester.pumpAndSettle();
  }
}

void main() {
  group('with nothing hidden', () {
    testWidgets('the front shows every part of the problem', (tester) async {
      await _pumpCard(tester, const AppSettings());

      expect(find.text('Easy'), findsOneWidget);
      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(
        find.text('Return indices of the two numbers adding up to target.'),
        findsOneWidget,
      );
      expect(find.text('Example 1'), findsOneWidget);
      expect(find.byType(TagChip), findsOneWidget);
    });

    testWidgets('the back shows the complexity and the code', (tester) async {
      await _pumpCard(tester, const AppSettings(), back: true);

      expect(find.text('1 Two Sum'), findsOneWidget);
      expect(find.text('Time: O(n)'), findsOneWidget);
      expect(find.text('Code'), findsOneWidget);
      expect(find.byType(LeetCodeCodeView), findsOneWidget);
    });
  });

  group('with every hide on', () {
    const hidden = AppSettings(
      leetCodeHideDifficulty: true,
      leetCodeHideTags: true,
      leetCodeHideQuestionName: true,
      leetCodeHideDescription: true,
      leetCodeHideExamples: true,
      leetCodeHideComplexity: true,
      leetCodeHideCode: true,
    );

    testWidgets('the front keeps nothing that names the problem', (
      tester,
    ) async {
      await _pumpCard(tester, hidden);

      expect(find.text('Easy'), findsNothing);
      expect(find.text('1 Two Sum'), findsNothing);
      expect(
        find.text('Return indices of the two numbers adding up to target.'),
        findsNothing,
      );
      expect(find.text('Example 1'), findsNothing);
      expect(find.byType(TagChip), findsNothing);
    });

    testWidgets('the back drops the complexity and code but keeps the '
        'write-up', (tester) async {
      await _pumpCard(tester, hidden, back: true);

      expect(find.text('1 Two Sum'), findsNothing);
      expect(find.text('Time: O(n)'), findsNothing);
      expect(find.text('Code'), findsNothing);
      expect(find.byType(LeetCodeCodeView), findsNothing);
      // The parts nothing hides — grading a card you can't read is no test.
      expect(find.text('Hash map of complements'), findsOneWidget);
      expect(find.text('Look up t - nums[i] as you go'), findsOneWidget);
    });
  });

  testWidgets('the deck menu saves a hide as a setting', (tester) async {
    _RecordingSettings.saved = null;
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          leetcodeProblemsProvider.overrideWith((ref) async => [_problem()]),
          settingsProvider.overrideWith(_RecordingSettings.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SafeArea(child: LeetCodeReviewDeck())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(PhosphorIconsRegular.gear));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide difficulty'));
    await tester.pumpAndSettle();

    expect(_RecordingSettings.saved?.leetCodeHideDifficulty, isTrue);
    // One toggle moves one setting.
    expect(_RecordingSettings.saved?.leetCodeHideTags, isFalse);
  });

  testWidgets('one hide leaves the rest of the card alone', (tester) async {
    await _pumpCard(tester, const AppSettings(leetCodeHideQuestionName: true));

    expect(find.text('1 Two Sum'), findsNothing);
    expect(find.text('Easy'), findsOneWidget);
    expect(
      find.text('Return indices of the two numbers adding up to target.'),
      findsOneWidget,
    );
    expect(find.byType(TagChip), findsOneWidget);
  });
}

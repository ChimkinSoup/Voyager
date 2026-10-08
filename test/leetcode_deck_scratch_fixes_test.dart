// Phase 17–18 LeetCode fixes: the Vim caret in a field with a prefix icon
// (BUG-151), difficulty labels readable in Light and an opaque Track button
// (BUG-153), a right-to-left
// tag keeps its count at the end (BUG-154), Esc leaves the scratch pad with
// Vim on too (BUG-156), a grade key taken by another grade swaps with it
// (BUG-159), and the code gutter widens past line 999 (BUG-160).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_difficulty_chip.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';
import 'package:voyager/features/leetcode/leetcode_tag_matrix.dart';
import 'package:voyager/features/settings/settings_page.dart';

final _t0 = DateTime.utc(2026, 9, 1, 12);

LeetCodeProblem _problem({String id = 'p1', List<String> tags = const []}) =>
    LeetCodeProblem(
      id: id,
      createdAt: _t0,
      updatedAt: _t0,
      title: 'Two Sum',
      questionFrontendId: '1',
      difficulty: LeetCodeDifficulty.easy,
      tags: tags,
      solvedAt: _t0,
    );

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

class _RecordingSettingsRepository implements SettingsRepository {
  _RecordingSettingsRepository([this.initial = const AppSettings()]);

  final AppSettings initial;
  final saved = <AppSettings>[];

  @override
  Future<AppSettings> getSettings() async =>
      saved.isEmpty ? initial : saved.last;

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async => saved.add(settings);

  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets(
    'BUG-151: the Vim layer lines up with the text past a prefix icon',
    (tester) async {
      final controller = TextEditingController(text: 'zebra3');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                width: 400,
                child: VoyagerTextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Search problems',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      final overlay = tester.getRect(find.byType(VimTextOverlay));
      final text = tester.getRect(find.byType(EditableText));
      expect(overlay.left, moreOrLessEquals(text.left, epsilon: 0.5));
    },
  );

  group('BUG-153 difficulty chips', () {
    /// The chip's fill and label colour as painted under [theme].
    Future<({Color fill, Color ink})> paint(
      WidgetTester tester,
      ThemeData theme,
      LeetCodeDifficulty d, {
      double tint = 0.14,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(body: LeetCodeDifficultyChip(d, tint: tint)),
        ),
      );
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byType(LeetCodeDifficultyChip),
          matching: find.byType(Container),
        ),
      );
      final fill = (box.decoration! as BoxDecoration).color!;
      final ink = tester.widget<Text>(find.text(labelForLeetCodeDifficulty(d)));
      return (
        fill: Color.alphaBlend(fill, theme.scaffoldBackgroundColor),
        ink: ink.style!.color!,
      );
    }

    for (final tint in [0.14, 0.16]) {
      testWidgets('every tier clears 4.5:1 in Light (tint $tint)', (
        tester,
      ) async {
        for (final d in LeetCodeDifficulty.values) {
          final chip = await paint(tester, VoyagerTheme.light(), d, tint: tint);
          expect(
            _contrast(chip.ink, chip.fill),
            greaterThanOrEqualTo(4.5),
            reason: d.name,
          );
        }
      });
    }

    testWidgets("Dark keeps LeetCode's own colours", (tester) async {
      for (final d in LeetCodeDifficulty.values) {
        final chip = await paint(tester, VoyagerTheme.dark(), d);
        expect(chip.ink, colorForLeetCodeDifficulty(d));
      }
    });
  });

  testWidgets('BUG-153: the Track button\'s backdrop shrinks with the press', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.light(),
        home: Scaffold(
          body: Center(
            child: GlassButton(
              label: 'Track',
              backdrop: const Color(0xFF123456),
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    final backdrop = find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == const Color(0xFF123456),
    );
    // Inside the button's own scale and clip, so it can never show as a
    // rim around the shrunken glass.
    expect(
      find.ancestor(of: backdrop, matching: find.byType(ScaleTransition)),
      findsWidgets,
    );
    expect(
      find.ancestor(of: backdrop, matching: find.byType(ClipRRect)),
      findsWidgets,
    );
  });

  testWidgets('BUG-154: a right-to-left tag keeps its count at the end', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LeetCodeTagMatrix(
            problems: [
              _problem(tags: ['مرحبا']),
            ],
          ),
        ),
      ),
    );
    final pill = tester.widget<Text>(find.textContaining('(1)'));
    final text = pill.data!;
    final painter = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(painter.dispose);
    Rect boxOf(int start, int end) => painter
        .getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: end),
        )
        .map((b) => b.toRect())
        .reduce((a, b) => a.expandToInclude(b));
    final tagStart = text.indexOf('م');
    final tag = boxOf(tagStart, tagStart + 'مرحبا'.length);
    final count = boxOf(text.indexOf('('), text.length);
    expect(count.left, greaterThanOrEqualTo(tag.right));
  });

  testWidgets('BUG-156: with Vim on, a second Esc leaves the scratch pad', (
    tester,
  ) async {
    final controller = LeetCodeCodeController(text: 'print(1)');
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                width: 400,
                height: 300,
                child: LeetCodeScratchPad(
                  problem: _problem(),
                  entry: const LeetCodeScratchEntry(language: 'python'),
                  controller: controller,
                  focusNode: focusNode,
                  onCodeChanged: (_) {},
                  onExpand: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();

    // Escape held down from Insert: the press is Vim's (Insert → Normal) and
    // the repeats that follow are not second presses, so the pad keeps the
    // keys.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('NORMAL'), findsOneWidget);
    expect(focusNode.hasFocus, isTrue);

    // Nothing left for Vim to cancel: a second press hands the keys back.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'BUG-159: a grade key another grade has is swapped, not shared',
    semanticsEnabled: false,
    (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _RecordingSettingsRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repo),
            journalsProvider.overrideWith((ref) async => []),
            todoListStatsProvider.overrideWith((ref) async => {}),
            authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
          ],
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.widgetWithText(Tab, 'Pages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grade: Easy'));
      await tester.pumpAndSettle();

      // F is Fail's.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();

      final saved = repo.saved.last;
      expect(saved.srsEasyKey, 'F');
      expect(saved.srsFailKey, 'E');
      expect(saved.srsHardKey, 'H');
      expect(saved.srsGoodKey, 'G');
      expect(find.text('Fail moved to E, since Easy took F'), findsOneWidget);
    },
  );

  testWidgets(
    'BUG-159: a key already on two grades moves off both',
    semanticsEnabled: false,
    (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Saved before the fix: Hard and Good share K.
      final repo = _RecordingSettingsRepository(
        const AppSettings(srsHardKey: 'K', srsGoodKey: 'K'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repo),
            journalsProvider.overrideWith((ref) async => []),
            todoListStatsProvider.overrideWith((ref) async => {}),
            authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
          ],
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.widgetWithText(Tab, 'Pages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grade: Fail'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();

      final saved = repo.saved.last;
      expect(saved.srsFailKey, 'K');
      // The first takes Fail's old key; the second its own default.
      expect(saved.srsHardKey, 'F');
      expect(saved.srsGoodKey, 'G');
      expect(saved.srsEasyKey, 'E');
      expect(
        find.text('Hard moved to F, Good moved to G, since Fail took K'),
        findsOneWidget,
      );
    },
  );

  testWidgets('BUG-160: four-digit line numbers stay on one row', (
    tester,
  ) async {
    final controller = LeetCodeCodeController(
      text: List.generate(1200, (i) => 'line_${i + 1} = ${i + 1}').join('\n'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: LeetCodeCodeInput(
              controller: controller,
              language: 'python',
              onLanguageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    final surface = find.byType(LeetCodeCodeSurface);
    final fields = find.descendant(
      of: surface,
      matching: find.byType(EditableText),
    );
    // The gutter is a field of its own, laid out line for line beside the
    // code: a number that wraps makes it the taller of the two.
    final gutter = tester.getSize(fields.first).height;
    final code = tester.getSize(fields.last).height;
    expect(gutter, moreOrLessEquals(code, epsilon: 0.5));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

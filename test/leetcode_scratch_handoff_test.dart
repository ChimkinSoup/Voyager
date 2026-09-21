// Ctrl+Enter in the scratch pad is the handoff: clipboard and browser together.
//
// The chord has to reach the collapsed pad, which has no toolbar to click, and
// it has to be *claimed* there — an unhandled Enter reaches the text input
// plugin and types a newline into the code it was meant to copy.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';

final _now = DateTime(2026, 1, 1);

final _problem = LeetCodeProblem(
  id: '1',
  createdAt: _now,
  updatedAt: _now,
  title: 'Two Sum',
  questionFrontendId: '1',
  difficulty: LeetCodeDifficulty.easy,
  tags: const ['hash-table'],
  solutions: const [LeetCodeSolution(algorithm: 'Hash map')],
  solvedAt: _now,
);

const _launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

/// What the clipboard and the launcher were asked to do, recorded off their
/// platform channels and put back at the end of the test.
({List<String> copied, List<String> launched}) _spyOnHandoff(
  WidgetTester tester,
) {
  final copied = <String>[];
  final launched = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  messenger.setMockMethodCallHandler(_launcherChannel, (call) async {
    if (call.method == 'launch') {
      launched.add((call.arguments as Map)['url'] as String);
    }
    return true;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_launcherChannel, null);
  });

  return (copied: copied, launched: launched);
}

Future<void> _pressSubmitChord(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Ctrl+Enter in the collapsed pad copies it and opens the problem',
    (tester) async {
      final spy = _spyOnHandoff(tester);

      final controller = LeetCodeCodeController(text: 'print(1)');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 300,
                child: LeetCodeScratchPad(
                  problem: _problem,
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
      );

      focusNode.requestFocus();
      await tester.pump();
      await _pressSubmitChord(tester);

      expect(spy.copied, ['print(1)']);
      expect(spy.launched, ['https://leetcode.com/problems/two-sum/']);
      // The chord is not an edit — the buffer is exactly what was copied.
      expect(controller.fullText, 'print(1)');
    },
  );

  testWidgets('Ctrl+Enter works from the expanded editor too', (tester) async {
    final spy = _spyOnHandoff(tester);

    final controller = LeetCodeCodeController(text: 'print(2)');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => openLeetCodeScratchOverlay(
                    context,
                    problem: _problem,
                    controller: controller,
                    anchorRect: const Rect.fromLTWH(0, 0, 200, 200),
                    language: 'python',
                    onCodeChanged: (_) {},
                    onLanguageChanged: (_) {},
                    onClear: () {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _pressSubmitChord(tester);

    expect(spy.copied, ['print(2)']);
    expect(spy.launched, ['https://leetcode.com/problems/two-sum/']);
    expect(controller.fullText, 'print(2)');
  });
}

// The scratch pad's Copy confirmation has to leave on its own.
//
// A toast raised without a `dwell` has no clock, and this one carries no
// actions either — so the "Code copied" card was click-through and pinned on
// screen for the life of the app.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
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

void main() {
  testWidgets('the Code copied toast dismisses itself', (tester) async {
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

    final controller = LeetCodeCodeController(text: 'print(1)');
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

    await tester.tap(find.byTooltip('Copy what you typed'));
    await tester.pump();
    await tester.pump();
    expect(copied, ['print(1)']);
    expect(find.text('Code copied'), findsOneWidget);

    // Past the dwell, plus the fade the dismissal animates.
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    expect(find.text('Code copied'), findsNothing);
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// Drags from the start of [from] to the end of [to], copies, and returns
/// what reached the clipboard.
Future<String?> _dragCopy(WidgetTester tester, String from, String to) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  final start = tester.getTopLeft(find.text(from)) + const Offset(1, 4);
  final end = tester.getBottomRight(find.text(to)) - const Offset(1, 4);
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
  return copied;
}

Widget _app(GaiaCardPart card) => MaterialApp(
  home: Scaffold(body: GaiaCardView(card: card)),
);

void main() {
  testWidgets('an activity card selects across its rows', (tester) async {
    await tester.pumpWidget(
      _app(
        const GaiaCardPart(
          id: 'a',
          kind: GaiaCardKind.control,
          state: GaiaCardState.accepted,
          tool: 'activity',
          input: {
            'activity': true,
            'app': 'Google Chrome',
            'total': 3,
            'steps': [
              {'label': 'Pressed Ctrl+L'},
              {'label': 'Typed "tokyo"'},
              {'label': 'Pressed Enter'},
            ],
          },
        ),
      ),
    );
    await tester.tap(find.text('3 actions in Google Chrome'));
    await tester.pumpAndSettle();
    expect(
      await _dragCopy(tester, 'Pressed Ctrl+L', 'Pressed Enter'),
      'Pressed Ctrl+L\nTyped "tokyo"\nPressed Enter',
    );
  });

  testWidgets('a tool chip selects across its calls and kept results', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GaiaActivityChip(
            label: 'Used Bash, os_windows',
            part: const GaiaActivityPart(
              ['Bash', 'os_windows'],
              details: ['ls -la', 'all'],
              ids: [null, 'w'],
            ),
            hasResult: (id) => id == 'w',
            result: (_) async =>
                const GaiaToolResult(text: '263412: Notes', isError: false),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Used Bash, os_windows'));
    await tester.pumpAndSettle();
    expect(
      await _dragCopy(tester, 'ls -la', '263412: Notes'),
      'ls -la\nos_windows\nall\n263412: Notes',
    );
  });

  testWidgets("a control card selects across its steps, not their numbers", (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const GaiaCardPart(
          id: 'c',
          kind: GaiaCardKind.control,
          state: GaiaCardState.voided,
          tool: 'os_steps',
          input: {
            'window': 'Notes',
            'steps': [
              {'label': 'Click "New note"'},
              {'label': 'Type "hello"'},
            ],
          },
        ),
      ),
    );
    expect(
      await _dragCopy(tester, 'Click "New note"', 'Type "hello"'),
      'Click "New note"\nType "hello"',
    );
  });
}

// BUG-215: Tab must never walk into a page that isn't on screen. The shell
// keeps every page mounted, and a hidden page's text field took whatever was
// typed next, then saved and synced it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

void main() {
  late FocusNode page0;
  late FocusNode page1;

  setUp(() {
    page0 = FocusNode(debugLabel: 'page 0');
    page1 = FocusNode(debugLabel: 'page 1');
    addTearDown(page0.dispose);
    addTearDown(page1.dispose);
  });

  Widget app(int index) => MaterialApp(
    home: Scaffold(
      body: ShellBranchContainer(
        currentIndex: index,
        children: [
          Column(children: [TextField(focusNode: page0)]),
          Column(
            children: [
              TextField(focusNode: page1),
              const TextButton(onPressed: null, child: Text('off')),
            ],
          ),
        ],
      ),
    ),
  );

  testWidgets('BUG-215: Tab stays out of a hidden page', (tester) async {
    await tester.pumpWidget(app(0));
    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();

    page1.requestFocus();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(page0.hasFocus, isFalse, reason: 'Tab ${i + 1}');
    }
  });

  testWidgets('BUG-215: the arrow keys stay out of a hidden page', (
    tester,
  ) async {
    final top = FocusNode(debugLabel: 'top');
    final bottom = FocusNode(debugLabel: 'bottom');
    final hidden = FocusNode(debugLabel: 'hidden');
    addTearDown(top.dispose);
    addTearDown(bottom.dispose);
    addTearDown(hidden.dispose);
    Widget button(FocusNode node) =>
        TextButton(focusNode: node, onPressed: () {}, child: const Text('b'));
    // The hidden page's button sits between the visible two, where a
    // directional search would pick it first.
    Widget buttons(int index) => MaterialApp(
      home: Scaffold(
        body: ShellBranchContainer(
          currentIndex: index,
          children: [
            Column(children: [const SizedBox(height: 100), button(hidden)]),
            Column(
              children: [
                button(top),
                const SizedBox(height: 200),
                button(bottom),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(buttons(0));
    await tester.pumpWidget(buttons(1));
    await tester.pumpAndSettle();

    top.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(hidden.hasFocus, isFalse);
    expect(bottom.hasFocus, isTrue);
  });

  testWidgets('Tab leaves a hidden page focus was left in', (tester) async {
    await tester.pumpWidget(app(1));
    await tester.pumpWidget(app(0));
    await tester.pumpAndSettle();
    page1.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(page1.hasFocus, isFalse);
    expect(page0.hasFocus, isTrue);
  });

  testWidgets('a page returned to is traversable again', (tester) async {
    await tester.pumpWidget(app(1));
    await tester.pumpWidget(app(0));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(page0.hasFocus, isTrue);
  });
}

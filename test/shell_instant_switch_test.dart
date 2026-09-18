// A hotkey's page switch lands at once: the capture opening over the page is
// the transition there, and the shell's crossfade under a blurred sheet cost
// more than a frame to raster. Everything else still crossfades.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

void main() {
  Future<void> pumpAt(WidgetTester tester, int index) => tester.pumpWidget(
    MaterialApp(
      home: ShellBranchContainer(
        currentIndex: index,
        children: const [Text('Journal'), Text('Finance')],
      ),
    ),
  );

  /// Whether anything is still fading: the departing branch sits in a
  /// fractional opacity while it does.
  bool fading(WidgetTester tester) => tester
      .widgetList<Opacity>(find.byType(Opacity))
      .any((o) => o.opacity > 0 && o.opacity < 1);

  testWidgets('a switch made under instantShellBranchSwitch lands at once', (
    tester,
  ) async {
    await pumpAt(tester, 0);
    instantShellBranchSwitch = true;
    addTearDown(() => instantShellBranchSwitch = false);
    await pumpAt(tester, 1);
    instantShellBranchSwitch = false;

    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(fading(tester), isFalse);
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('any other switch still crossfades', (tester) async {
    await pumpAt(tester, 0);
    await pumpAt(tester, 1);
    await tester.pump(const Duration(milliseconds: 100));

    expect(fading(tester), isTrue);
    await tester.pumpAndSettle();
  });
}

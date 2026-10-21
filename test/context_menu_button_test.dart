// A ⋯ button's menu hangs from its left edge; at the right of the screen it
// ends at the button's right edge rather than sitting off to its left.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

Future<(Rect button, Rect menu)> _open(
  WidgetTester tester,
  Alignment where, {
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: VoyagerTheme.light(),
      home: Scaffold(
        // Inset from the screen's edges, which the menu keeps 8px off.
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: Align(
            alignment: where,
            child: ContextMenuButton(
              enabled: enabled,
              items: [ContextMenuItem(label: 'Rename', onTap: () {})],
            ),
          ),
        ),
      ),
    ),
  );
  final button = tester.getRect(find.byType(ContextMenuButton));
  await tester.tap(find.byType(ContextMenuButton));
  await tester.pumpAndSettle();
  final panel = find.ancestor(
    of: find.text('Rename'),
    matching: find.byType(GlassSurface),
  );
  return (button, panel.evaluate().isEmpty ? Rect.zero : tester.getRect(panel));
}

void main() {
  testWidgets('on the left, the menu starts at the button\'s left edge, under '
      'it', (tester) async {
    final (button, menu) = await _open(tester, Alignment.topLeft);
    expect(menu.left, moreOrLessEquals(button.left, epsilon: 1));
    expect(menu.top, greaterThanOrEqualTo(button.bottom - 1));
  });

  testWidgets('on the right, the menu ends at the button\'s right edge', (
    tester,
  ) async {
    final (button, menu) = await _open(tester, Alignment.topRight);
    expect(menu.right, moreOrLessEquals(button.right, epsilon: 1));
    expect(menu.top, greaterThanOrEqualTo(button.bottom - 1));
  });

  testWidgets('a second click on the button closes its menu', (tester) async {
    await _open(tester, Alignment.center);
    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.byType(ContextMenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsNothing);
  });

  testWidgets('disabled, it opens nothing', (tester) async {
    await _open(tester, Alignment.center, enabled: false);
    expect(find.text('Rename'), findsNothing);
  });
}

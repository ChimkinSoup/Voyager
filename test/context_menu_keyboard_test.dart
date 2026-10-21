// While a context menu is open its keys are its own: Esc closed the menu and,
// heard a second time, the dialog or viewer under it too, and arrows and
// Enter went to the page, so a ⋯ menu couldn't be used without a mouse.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

Future<void> _pumpButton(
  WidgetTester tester,
  List<ContextMenuItem> items, {
  VoidCallback? onPageEsc,
  VoidCallback? onPageDown,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: VoyagerTheme.light(),
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): ?onPageEsc,
            const SingleActivator(LogicalKeyboardKey.arrowDown): ?onPageDown,
          },
          child: Focus(
            autofocus: true,
            child: Center(child: ContextMenuButton(items: items)),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(ContextMenuButton));
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Esc closes the menu and leaves the dialog under it; the next '
      'Esc closes the dialog', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVoyagerDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Manage'),
                  content: ContextMenuButton(
                    items: [ContextMenuItem(label: 'Rename', onTap: () {})],
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ContextMenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Manage'), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets("Esc closes the menu, not the page's own Esc binding too", (
    tester,
  ) async {
    var pageEsc = 0;
    await _pumpButton(tester, [
      ContextMenuItem(label: 'Rename', onTap: () {}),
    ], onPageEsc: () => pageEsc++);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(find.text('Rename'), findsNothing);
    expect(pageEsc, 0);
  });

  testWidgets('arrows skip a disabled item and wrap; Enter picks', (
    tester,
  ) async {
    final picked = <String>[];
    var pageDown = 0;
    await _pumpButton(tester, [
      ContextMenuItem(label: 'Rename', onTap: () => picked.add('Rename')),
      const ContextMenuItem(label: 'Archive'),
      ContextMenuItem(label: 'Delete', onTap: () => picked.add('Delete')),
    ], onPageDown: () => pageDown++);

    await _press(tester, LogicalKeyboardKey.arrowDown); // Rename
    await _press(tester, LogicalKeyboardKey.arrowDown); // Delete
    await _press(tester, LogicalKeyboardKey.arrowDown); // Rename again
    await _press(tester, LogicalKeyboardKey.arrowUp); // Delete
    await _press(tester, LogicalKeyboardKey.enter);
    expect(picked, ['Delete']);
    expect(find.text('Rename'), findsNothing);
    expect(pageDown, 0);
  });

  testWidgets('Right opens a submenu, Left backs out, Enter picks in it', (
    tester,
  ) async {
    final picked = <String>[];
    await _pumpButton(tester, [
      ContextMenuItem(
        label: 'Move to',
        children: [
          ContextMenuItem(label: 'Work', onTap: () => picked.add('Work')),
          ContextMenuItem(label: 'Home', onTap: () => picked.add('Home')),
        ],
      ),
      ContextMenuItem(label: 'Rename', onTap: () => picked.add('Rename')),
    ]);

    await _press(tester, LogicalKeyboardKey.arrowDown); // Move to
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Work'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('Work'), findsNothing);

    await _press(tester, LogicalKeyboardKey.arrowRight); // Work
    await _press(tester, LogicalKeyboardKey.arrowDown); // Home
    await _press(tester, LogicalKeyboardKey.enter);
    expect(picked, ['Home']);
    expect(find.text('Move to'), findsNothing);
  });

  testWidgets('a field right-clicked keeps its focus and selection', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello world');
    final focus = FocusNode();
    final menu = GlobalKey<ContextMenuRegionState>();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.light(),
        home: Scaffold(
          body: ContextMenuRegion(
            key: menu,
            items: [ContextMenuItem(label: 'Rename', onTap: () {})],
            child: TextField(controller: controller, focusNode: focus),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();

    // Opened as the right-click does; the field takes a real one for its own
    // menu.
    menu.currentState!.openMenuAt(tester.getCenter(find.byType(TextField)));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.escape);

    expect(find.text('Rename'), findsNothing);
    expect(focus.hasFocus, isTrue);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
  });
}

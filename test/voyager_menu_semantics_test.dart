import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';

void main() {
  testWidgets('menu semantics raise no assertion', (tester) async {
    // The catalog menu is what the Manage dialogs hang off each row; its
    // entries carry SemanticsRole.menuItem, which used to trip an assertion
    // when the menu opened.
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.light(),
        home: Scaffold(
          body: Center(
            child: PopupMenuButton<VoyagerMenuCatalogEntry>(
              onSelected: (_) {},
              itemBuilder: (context) => buildCatalogMenu(
                context,
                from: configurableManageMenuEntries,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<VoyagerMenuCatalogEntry>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });
}

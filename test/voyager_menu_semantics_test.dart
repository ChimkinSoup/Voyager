import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';

void main() {
  testWidgets('menu semantics raise no assertion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: RoundedDropdown<String?>(
                value: 'a',
                items: const [
                  RoundedDropdownItem<String?>(
                    value: 'a',
                    label: 'this should be open',
                    trailing: '0 | 1',
                  ),
                  RoundedDropdownItem<String?>(
                    value: 'b',
                    label: 'another list',
                  ),
                ],
                onChanged: (_) {},
                onManage: (value, action) async {},
                manageMenuEntriesFor: (_) => entityManageMenuEntries,
                onAddList: () {},
              ),
            ),
          ),
        ),
      ),
    );

    // Level 1: the dropdown's own menu.
    await tester.tap(find.text('this should be open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.text('Add list'), findsOneWidget);

    // Level 2: the ⋮ manage menu, whose entries carry SemanticsRole.menuItem.
    await tester.tap(find.byIcon(PhosphorIconsBold.dotsThreeVertical).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });
}

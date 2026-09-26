// A popover left open on one nav page must not still be open on return:
// branches stay mounted while hidden, and popovers push onto the branch's own
// navigator, so leaving the branch has to close them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

void main() {
  testWidgets('leaving a branch closes its open popover', (tester) async {
    late StatefulNavigationShell shell;
    final router = GoRouter(
      initialLocation: '/todo',
      routes: [
        StatefulShellRoute(
          builder: (_, _, navigationShell) {
            shell = navigationShell;
            return navigationShell;
          },
          navigatorContainerBuilder: shellBranchContainerBuilder(),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/todo',
                  builder: (_, _) => Scaffold(
                    body: ScopeSwitcher<int>(
                      items: const [
                        ScopeSwitcherItem(value: 0, label: 'All lists'),
                        ScopeSwitcherItem(value: 1, label: 'Groceries'),
                      ],
                      selectedValue: 0,
                      onSelected: (_) {},
                      accent: Colors.blue,
                    ),
                  ),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/journal', builder: (_, _) => const Text('J')),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await tester.tap(find.text('All lists'));
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsOneWidget);

    shell.goBranch(1);
    await tester.pumpAndSettle();
    shell.goBranch(0);
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsNothing);
  });
}

// The due-reminder stickies sit above every navigator and used to draw over
// the dialogs and popovers the user opened (BUG-041). They now step aside
// while [popupRouteOpen] is set: a popup is open on the root navigator or on
// a nested one (the shell's, a page's branch).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/routing/popup_route_observer.dart';

void main() {
  tearDown(PopupRouteObserver.reset);

  testWidgets('a dialog on the root or a popup on a nested navigator', (
    tester,
  ) async {
    final nestedKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [PopupRouteObserver()],
        home: Scaffold(
          body: Navigator(
            key: nestedKey,
            observers: [PopupRouteObserver()],
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => const Text('page')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(popupRouteOpen.value, isFalse);

    final page = tester.element(find.text('page'));
    showDialog<void>(context: page, builder: (_) => const Text('dialog'));
    await tester.pumpAndSettle();
    expect(popupRouteOpen.value, isTrue);
    Navigator.of(tester.element(find.text('dialog'))).pop();
    await tester.pumpAndSettle();
    expect(popupRouteOpen.value, isFalse);

    showDialog<void>(
      context: page,
      useRootNavigator: false,
      builder: (_) => const Text('popover'),
    );
    await tester.pumpAndSettle();
    expect(popupRouteOpen.value, isTrue);
    nestedKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(popupRouteOpen.value, isFalse);

    // A page pushed on top is not a popup.
    nestedKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('second')),
    );
    await tester.pumpAndSettle();
    expect(popupRouteOpen.value, isFalse);
  });
}

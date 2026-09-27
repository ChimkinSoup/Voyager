// The transaction sheet's Store / Source combobox, and through it the shared
// [SuggestionList]: picking by click and by keyboard, and keeping the
// highlighted row in view in a list long enough to scroll.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/finance/finance_origin_field.dart';

final _stores = [for (var i = 0; i < 8; i++) 'Store $i'];

Future<TextEditingController> _pumpField(
  WidgetTester tester, {
  List<String>? origins,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = TextEditingController();
  addTearDown(controller.dispose);
  final focusNode = FocusNode();
  addTearDown(focusNode.dispose);

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: FinanceOriginField(
            controller: controller,
            focusNode: focusNode,
            origins: origins ?? _stores,
            label: 'Store',
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
  return controller;
}

/// The suggestion list's own viewport: the field has a Scrollable of its own
/// too, and the overlay's is the one built last.
Rect _viewport(WidgetTester tester) =>
    tester.getRect(find.byType(Scrollable).last);

/// A suggestion row's label, as opposed to the text typed into the field.
Finder _row(String origin) => find.descendant(
  of: find.byType(Scrollable).last,
  matching: find.text(origin),
);

/// The whole row [origin] is on, padding and all, rather than its label.
Rect _rowRect(WidgetTester tester, String origin) => tester.getRect(
  find.ancestor(of: _row(origin), matching: find.byType(GestureDetector)).first,
);

bool _shown(WidgetTester tester, String origin) {
  final row = tester.getRect(_row(origin));
  final viewport = _viewport(tester);
  return row.top >= viewport.top && row.bottom <= viewport.bottom;
}

void main() {
  testWidgets(
    'clicking a suggestion with the mouse fills the field',
    (tester) async {
      final controller = await _pumpField(tester);

      await tester.tap(_row('Store 1'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(controller.text, 'Store 1');
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets('the arrows scroll the highlight into view', (tester) async {
    final controller = await _pumpField(tester);
    expect(_shown(tester, 'Store 7'), isFalse);

    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(_shown(tester, 'Store 7'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, 'Store 7');
  });

  testWidgets(
    'a keyboard scroll under a resting pointer keeps the keyboard highlight',
    (tester) async {
      final controller = await _pumpField(tester);

      // Rest the pointer on a row near the bottom of the view, which takes
      // the highlight.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: tester.getCenter(_row('Store 5')) - const Offset(0, 4),
      );
      await mouse.moveTo(tester.getCenter(_row('Store 5')));
      await tester.pumpAndSettle();

      // Down to the last row: the list scrolls, sliding another row under
      // the still pointer.
      for (var i = 0; i < 2; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controller.text, 'Store 7');
    },
  );

  testWidgets('a wheel scroll moves the highlight to the row under it', (
    tester,
  ) async {
    final controller = await _pumpField(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    final point = tester.getCenter(_row('Store 1'));
    await mouse.addPointer(location: point - const Offset(0, 4));
    await mouse.moveTo(point);
    await tester.pumpAndSettle();

    await tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: const Offset(0, 500)),
    );
    await tester.pumpAndSettle();

    final under = _stores.firstWhere(
      (origin) => _rowRect(tester, origin).contains(point),
    );
    expect(under, isNot('Store 1'), reason: 'the list did scroll');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, under);
  });

  testWidgets('typing brings a scrolled list back to its first row', (
    tester,
  ) async {
    await _pumpField(tester);

    final point = tester.getCenter(_row('Store 1'));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: const Offset(0, 500)),
    );
    await tester.pumpAndSettle();
    expect(_shown(tester, 'Store 0'), isFalse);

    // Still all eight, so still more than the list's cap.
    await tester.enterText(find.byType(TextField), 'S');
    await tester.pumpAndSettle();
    expect(_shown(tester, 'Store 0'), isTrue);
  });

  testWidgets('rows grow with the text instead of clipping it', (tester) async {
    await _pumpField(
      tester,
      origins: const ['Walmart', 'Costco'],
      textScale: 3,
    );

    final text = tester.getRect(_row('Walmart'));
    final row = _rowRect(tester, 'Walmart');
    expect(row.height, greaterThanOrEqualTo(text.height));
    expect(text.height, greaterThan(32));
  });
}

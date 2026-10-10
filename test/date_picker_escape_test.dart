// The date picker's key handler claimed every key, so Esc never reached the
// popover's route and the picker stayed open. Esc now closes it without a
// pick, as a click outside does.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

void main() {
  testWidgets('Esc closes the picker without picking a day', (tester) async {
    var closed = false;
    DateTimeRange? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (buttonContext) => TextButton(
                onPressed: () async {
                  result = await showContextualPopover<DateTimeRange>(
                    context: buttonContext,
                    buttonContext: buttonContext,
                    width: 320,
                    height: 380,
                    builder: (_) => DateSelectorPopover(
                      initialStartDate: DateTime(2026, 10, 3),
                      initialEndDate: DateTime(2026, 10, 3),
                      singleDateMode: true,
                    ),
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(DateSelectorPopover), findsOneWidget);

    // Move the highlight first: Esc must not pick it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(DateSelectorPopover), findsNothing);
    expect(closed, isTrue);
    expect(result, isNull);
  });
}

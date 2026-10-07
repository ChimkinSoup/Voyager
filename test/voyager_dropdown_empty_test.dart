// A dropdown with no value and no caret (the tracker value pickers) must still
// be one option tall and open its menu, by click and by Space.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';

Widget _field({bool autofocus = false}) => MaterialApp(
  theme: VoyagerTheme.dark(),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 280,
        child: VoyagerDropdownButtonFormField<String>(
          showCaret: false,
          autofocus: autofocus,
          decoration: const InputDecoration(labelText: 'Value', isDense: true),
          items: const [
            DropdownMenuItem(value: 'A', child: Text('A')),
            DropdownMenuItem(value: 'B', child: Text('B')),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('an empty field without a caret can be clicked open', (
    tester,
  ) async {
    await tester.pumpWidget(_field());
    // Its height doesn't come from a hidden copy of an option.
    expect(find.text('A'), findsNothing);
    final tapTarget = tester.getSize(find.byType(InkWell).first);
    expect(tapTarget.height, greaterThan(16));

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('an autofocused field opens on Space', (tester) async {
    await tester.pumpWidget(_field(autofocus: true));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('with a small option style, empty and filled are equally tall', (
    tester,
  ) async {
    const small = TextStyle(fontSize: 10);
    Future<double> height(String? value) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: VoyagerDropdownButtonFormField<String>(
                  key: UniqueKey(),
                  initialValue: value,
                  showCaret: false,
                  style: small,
                  decoration: const InputDecoration(
                    isDense: true,
                    isCollapsed: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'A',
                      child: Text('A', style: small),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(InputDecorator)).height;
    }

    expect(await height(null), await height('A'));
  });
}

// The rollers' highlight is a rebuild, not a scroll: each item compares its own
// index against the state's `_display*Item`. A programmatic move — the end time
// sliding because the duration changed — jumps the wheel with
// `onSelectedItemChanged` deliberately muted, so the indices have to be written
// through setState or the *old* numbers stay lit in the accent colour while the
// wheel underneath shows the new ones.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/voyager_time_picker_spinner.dart';

const _normal = TextStyle(color: Color(0xFF888888), fontSize: 16);
const _highlight = TextStyle(color: Color(0xFFFF0000), fontSize: 16);

/// Every roller label currently drawn in the highlight colour.
List<String> _lit(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .where((t) => t.style?.color == _highlight.color)
    .map((t) => t.data ?? '')
    .toList();

Widget _host(DateTime time) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: VoyagerTimePickerSpinner(
        time: time,
        onTimeChange: (_) {},
        normalTextStyle: _normal,
        highlightedTextStyle: _highlight,
      ),
    ),
  ),
);

void main() {
  testWidgets('a programmatic time change relights the new numbers', (
    tester,
  ) async {
    await tester.pumpWidget(_host(DateTime(2026, 1, 1, 10, 15)));
    await tester.pumpAndSettle();
    expect(_lit(tester), containsAll(<String>['10', '15', 'AM']));

    // The end time sliding because the duration was edited: the widget is
    // handed a new time it did not scroll to itself.
    await tester.pumpWidget(_host(DateTime(2026, 1, 1, 11, 45)));
    await tester.pumpAndSettle();

    final lit = _lit(tester);
    expect(lit, containsAll(<String>['11', '45', 'AM']));
    expect(lit, isNot(contains('10')));
    expect(lit, isNot(contains('15')));
  });

  testWidgets('any minute can be selected, not just multiples of five', (
    tester,
  ) async {
    await tester.pumpWidget(_host(DateTime(2026, 1, 1, 10, 7)));
    await tester.pumpAndSettle();
    expect(_lit(tester), containsAll(<String>['10', '07', 'AM']));
  });
}

// Fields that open with their text selected keep it selected through the first
// click, so the next keystroke replaces it. On desktop Flutter drops the
// selection to a caret on mouse *down*, and these fields only put it back on
// mouse *up* — so for as long as the button was held the highlight vanished,
// then blinked back. Each check here holds the button down across a frame and
// looks at what that frame would paint.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';

void main() {
  final eightPm = DateTime(2026, 9, 21, 20, 0);
  final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pump();
  }

  TextSelection selectionOf(WidgetTester tester, Finder field) =>
      tester.widget<EditableText>(field).controller.selection;

  TextSelection all(WidgetTester tester, Finder field) => TextSelection(
    baseOffset: 0,
    extentOffset: tester.widget<EditableText>(field).controller.text.length,
  );

  /// Presses the mouse on [field], lets a frame render with the button held,
  /// and returns the selection that frame showed; then releases.
  Future<TextSelection> selectionWhileHeld(
    WidgetTester tester,
    Finder field,
  ) async {
    final gesture = await tester.startGesture(
      tester.getCenter(field),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final held = selectionOf(tester, field);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    return held;
  }

  testWidgets('reminder time: first click keeps the time selected', (
    tester,
  ) async {
    await pump(tester, TimeSelectorPopover(initialTime: eightPm));
    final field = find.byType(EditableText);

    expect(await selectionWhileHeld(tester, field), all(tester, field));
    expect(selectionOf(tester, field), all(tester, field));

    // The click after that places the caret, as any field would.
    expect((await selectionWhileHeld(tester, field)).isCollapsed, isTrue);
  }, variant: desktop);

  testWidgets('time range: first click on the start keeps it selected', (
    tester,
  ) async {
    await pump(
      tester,
      TimeRangePopover(
        initialStart: eightPm,
        initialEnd: eightPm.add(const Duration(hours: 1)),
      ),
    );
    final start = find.byType(EditableText).first;
    final end = find.byType(EditableText).last;

    expect(await selectionWhileHeld(tester, start), all(tester, start));
    expect(await selectionWhileHeld(tester, end), all(tester, end));
    expect((await selectionWhileHeld(tester, end)).isCollapsed, isTrue);
  }, variant: desktop);

  testWidgets('reminder date+time: first click keeps the time selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Center(
                child: SizedBox(
                  width: 700,
                  height: 500,
                  child: Material(
                    child: DateTimeSelectorPopover(initialDateTime: eightPm),
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byType(EditableText);
    expect(selectionOf(tester, field), all(tester, field));

    expect(await selectionWhileHeld(tester, field), all(tester, field));
    expect((await selectionWhileHeld(tester, field)).isCollapsed, isTrue);
  }, variant: desktop);

  testWidgets('ranking score: first click, and a click back in, keep it '
      'selected', (tester) async {
    await pump(
      tester,
      RankingScorePopover(
        value: 7.5,
        scoreMax: 10,
        precision: RankingScorePrecision.tenths,
        label: 'Dune',
      ),
    );
    final field = find.byType(EditableText);

    expect(await selectionWhileHeld(tester, field), all(tester, field));

    tester.widget<EditableText>(field).focusNode.unfocus();
    await tester.pump();
    expect(await selectionWhileHeld(tester, field), all(tester, field));
    expect((await selectionWhileHeld(tester, field)).isCollapsed, isTrue);
  }, variant: desktop);
}

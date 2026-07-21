import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the layering rules the analytics grid's `_StatTile` is built on.
///
/// A tile puts its tap/hold-to-drag target *behind* its content, so that the
/// chart and the heatmap squares — which handle their own presses — claim the
/// pointer first and everything else falls through to open the detail popup.
/// That only works if every inert layer above the target is transparent to hit
/// testing, and two very ordinary widgets are not:
///
///  * `BoxDecoration` — `RenderDecoratedBox.hitTestSelf` asks the decoration
///    whether the point is inside its *shape*, which has nothing to do with
///    how transparent the paint is. So a decorated `Container` around the
///    content swallows presses anywhere in the tile.
///  * `Text` — `RenderParagraph.hitTestSelf` is unconditionally true, so every
///    label (tracker name, cadence, axis dates) is its own dead zone.
///
/// The fix on both counts is to keep them out of the pointer's way: the fill
/// and border get their own [IgnorePointer] layer below the gestures, and the
/// inert labels are wrapped in [IgnorePointer] where they sit.
void main() {
  Widget build({required bool guarded, required VoidCallback onTap}) {
    final decoration = BoxDecoration(
      color: Colors.blue.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
    );
    const label = Align(alignment: Alignment.centerLeft, child: Text('label'));
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            if (guarded)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(decoration: decoration),
                ),
              ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
              ),
            ),
            SizedBox(
              height: 100,
              width: 400,
              child: guarded
                  ? const IgnorePointer(child: label)
                  : DecoratedBox(decoration: decoration, child: label),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('unguarded: decoration and label both swallow the press', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(build(guarded: false, onTap: () => taps++));

    await tester.tapAt(const Offset(300, 50)); // empty chrome
    await tester.tap(find.text('label')); // the label itself
    await tester.pumpAndSettle();
    expect(taps, 0);
  });

  testWidgets('guarded: both fall through to the target behind', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(build(guarded: true, onTap: () => taps++));

    await tester.tapAt(const Offset(300, 50)); // empty chrome
    await tester.tap(find.text('label')); // the label itself
    await tester.pumpAndSettle();
    expect(taps, 2);
  });
}

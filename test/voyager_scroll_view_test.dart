import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// The app's own physics, so the test overscrolls the way the app does.
class _BouncingBehavior extends ScrollBehavior {
  const _BouncingBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.fast,
        parent: RangeMaintainingScrollPhysics(),
      );
}

void main() {
  testWidgets(
    'overscroll survives a relayout under a hovering cursor',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final fieldControllers =
          List.generate(6, (i) => TextEditingController(text: 'field $i'));
      addTearDown(() {
        for (final c in fieldControllers) {
          c.dispose();
        }
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: VimEnabledScope(
              enabled: false,
              child: Scaffold(
                body: SizedBox(
                  height: 600,
                  child: ScrollConfiguration(
                    behavior: const _BouncingBehavior(),
                    child: VoyagerScrollView(
                      controller: scrollController,
                      child: Column(
                        children: [
                          for (var i = 0; i < 6; i++) ...[
                            const SizedBox(height: 40),
                            VoyagerTextField(
                              controller: fieldControllers[i],
                              maxLines: i.isEven ? 1 : 4,
                              decoration:
                                  InputDecoration(labelText: 'Field $i'),
                            ),
                          ],
                          const SizedBox(height: 800),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A parked cursor is the trigger: the content slides under it while
      // scrolling, so hover keeps crossing field boundaries, and Material
      // relayouts a TextField on hover enter/exit. Flutter's own
      // SingleChildScrollView clamps the offset back to the edge on every one
      // of those relayouts, which is the jitter this widget exists to fix.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 300));
      addTearDown(() => mouse.removePointer());
      await tester.pump();

      // Trackpad pan, the only input that can overscroll — the mouse wheel
      // path clamps to range and never rubber-bands.
      final pan = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pan.panZoomStart(const Offset(400, 300));
      await tester.pump();

      var previous = 0.0;
      var pan0 = Offset.zero;
      for (var i = 0; i < 30; i++) {
        pan0 += const Offset(0, 14);
        await pan.panZoomUpdate(const Offset(400, 300), pan: pan0);
        await tester.pump(const Duration(milliseconds: 16));

        final offset = scrollController.offset;
        expect(
          offset,
          lessThanOrEqualTo(previous),
          reason: 'overscroll snapped back from $previous to $offset on frame '
              '$i instead of holding the rubber band',
        );
        previous = offset;
      }

      // Past the top edge the whole way, and still bouncing.
      expect(scrollController.offset, lessThan(-50));

      await pan.panZoomEnd();
      await tester.pumpAndSettle();
      expect(scrollController.offset, 0);
    },
  );

  testWidgets('lets its cross axis shrink-wrap the child', (tester) async {
    // Horizontal scrollers in the app sit in Columns and rely on the viewport
    // taking its height from the content, which a sliver viewport would not do.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              VoyagerScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [SizedBox(height: 42, width: 2000)],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(VoyagerScrollView)).height, 42);
  });
}

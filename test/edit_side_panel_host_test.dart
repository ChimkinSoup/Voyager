import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/edit_side_panel_host.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';

void main() {
  group('EditSidePanelMetrics', () {
    test('prefers push while the list keeps its floor', () {
      expect(
        EditSidePanelMetrics.shouldPush(
          pageWidth: 900,
          panelWidth: EditSidePanelMetrics.defaultWidth,
          listMinWidth: EditSidePanelMetrics.todoListMinWidth,
        ),
        isTrue,
      );
    });

    test('overlays when a half-width page would crush the list', () {
      // ~624px is the page area inside the desktop minimum window.
      expect(
        EditSidePanelMetrics.shouldPush(
          pageWidth: 624,
          panelWidth: EditSidePanelMetrics.defaultWidth,
          listMinWidth: EditSidePanelMetrics.todoListMinWidth,
        ),
        isFalse,
      );
    });

    test('jobs needs a wider list floor than todo', () {
      const pageWidth = 780.0;
      expect(
        EditSidePanelMetrics.shouldPush(
          pageWidth: pageWidth,
          panelWidth: EditSidePanelMetrics.defaultWidth,
          listMinWidth: EditSidePanelMetrics.todoListMinWidth,
        ),
        isTrue,
      );
      expect(
        EditSidePanelMetrics.shouldPush(
          pageWidth: pageWidth,
          panelWidth: EditSidePanelMetrics.defaultWidth,
          listMinWidth: EditSidePanelMetrics.jobsListMinWidth,
        ),
        isFalse,
      );
    });

    test('clamps width between min and the page fraction cap', () {
      expect(
        EditSidePanelMetrics.clampWidth(100, 1600),
        EditSidePanelMetrics.minWidth,
      );
      expect(
        EditSidePanelMetrics.clampWidth(9999, 1600),
        EditSidePanelMetrics.maxWidth,
      );
      expect(
        EditSidePanelMetrics.clampWidth(500, 900),
        closeTo(900 * EditSidePanelMetrics.maxFraction, 0.1),
      );
      // Narrow page: the cap bottoms out at the panel's own minimum rather
      // than opening up to the whole page, so the list is never covered.
      expect(
        EditSidePanelMetrics.clampWidth(EditSidePanelMetrics.defaultWidth, 624),
        EditSidePanelMetrics.minWidth,
      );
    });

    test('the cap never lets the panel take more than half the page', () {
      for (var pageWidth = 400.0; pageWidth <= 2000; pageWidth += 7) {
        final cap = EditSidePanelMetrics.maxAllowed(pageWidth);
        expect(
          cap,
          greaterThanOrEqualTo(EditSidePanelMetrics.minWidth),
          reason: 'an empty clamp range at $pageWidth would throw',
        );
        if (pageWidth >= 2 * EditSidePanelMetrics.minWidth) {
          expect(
            pageWidth - cap,
            greaterThanOrEqualTo(cap),
            reason: 'the list keeps the majority at $pageWidth',
          );
        }
      }
    });

    test('the cap never shrinks as the page grows', () {
      var previous = 0.0;
      for (var pageWidth = 320.0; pageWidth <= 2400; pageWidth += 1) {
        final cap = EditSidePanelMetrics.maxAllowed(pageWidth);
        expect(
          cap,
          greaterThanOrEqualTo(previous),
          reason: 'widening the window jumped the panel narrower at $pageWidth',
        );
        previous = cap;
      }
    });
  });

  testWidgets('push mode insets the list; overlay mode does not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AnimationController(
      vsync: tester,
      duration: EditSidePanelMetrics.duration,
      value: 1,
    );
    addTearDown(controller.dispose);

    Future<void> pumpAt(double pageWidth, double listMinWidth) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: pageWidth,
              height: 400,
              child: EditSidePanelHost(
                animation: controller,
                listMinWidth: listMinWidth,
                storedWidth: EditSidePanelMetrics.defaultWidth,
                onWidthCommitted: (_) {},
                list: const ColoredBox(
                  key: Key('list-pane'),
                  color: Colors.blue,
                ),
                panel: const ColoredBox(
                  key: Key('panel-pane'),
                  color: Colors.red,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpAt(1100, EditSidePanelMetrics.todoListMinWidth);
    expect(
      tester.getSize(find.byKey(const Key('list-pane'))).width,
      closeTo(1100 - EditSidePanelMetrics.defaultWidth, 1),
    );

    // Jobs' wider list floor is what still forces overlay at the desktop
    // minimum, now that the cap holds the panel to 320 there.
    await pumpAt(624, EditSidePanelMetrics.jobsListMinWidth);
    // Overlay: the list keeps the full page width under the panel.
    expect(
      tester.getSize(find.byKey(const Key('list-pane'))).width,
      closeTo(624, 1),
    );
    expect(find.byType(ResizablePaneDivider), findsOneWidget);
  });

  testWidgets(
    'overlay lays an opaque backdrop under the panel; push does not',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AnimationController(
        vsync: tester,
        duration: EditSidePanelMetrics.duration,
        value: 1,
      );
      addTearDown(controller.dispose);
      final theme = ThemeData(scaffoldBackgroundColor: const Color(0xFF123456));

      Future<void> pumpAt(double pageWidth, double listMinWidth) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SizedBox(
                width: pageWidth,
                height: 400,
                child: EditSidePanelHost(
                  animation: controller,
                  listMinWidth: listMinWidth,
                  storedWidth: EditSidePanelMetrics.defaultWidth,
                  onWidthCommitted: (_) {},
                  list: const SizedBox.expand(),
                  // The three real editors draw no fill of their own.
                  panel: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      Finder backdrop() => find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == theme.scaffoldBackgroundColor,
      );

      await pumpAt(624, EditSidePanelMetrics.jobsListMinWidth);
      expect(
        backdrop(),
        findsOneWidget,
        reason: 'without it the list renders straight through the editor',
      );
      expect(
        tester.getSize(backdrop()).width,
        closeTo(EditSidePanelMetrics.minWidth, 1),
      );

      await pumpAt(1400, EditSidePanelMetrics.jobsListMinWidth);
      expect(
        backdrop(),
        findsNothing,
        reason: 'push leaves nothing behind the panel to cover',
      );
    },
  );

  testWidgets('the divider draws no line of its own beside the panel', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: EditSidePanelMetrics.duration,
      value: 1,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 400,
            child: EditSidePanelHost(
              animation: controller,
              listMinWidth: EditSidePanelMetrics.todoListMinWidth,
              storedWidth: null,
              onWidthCommitted: (_) {},
              list: const SizedBox.expand(),
              panel: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The panel already draws its own left hairline; a grab line beside it
    // read as a double rule.
    expect(
      tester
          .widget<ResizablePaneDivider>(find.byType(ResizablePaneDivider))
          .showLine,
      isFalse,
    );
  });

  testWidgets('dragging stops dead at the bounds and commits the width', (
    tester,
  ) async {
    const pageWidth = 1400.0;
    // Wider than the default 800 test surface, which would otherwise squeeze
    // the SizedBox below and move the cap under the panel.
    tester.view.physicalSize = const Size(pageWidth, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AnimationController(
      vsync: tester,
      duration: EditSidePanelMetrics.duration,
      value: 1,
    );
    addTearDown(controller.dispose);
    final committed = <double?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: pageWidth,
            height: 400,
            child: EditSidePanelHost(
              animation: controller,
              listMinWidth: EditSidePanelMetrics.todoListMinWidth,
              storedWidth: null,
              onWidthCommitted: committed.add,
              list: const SizedBox.expand(),
              panel: const ColoredBox(
                key: Key('panel-pane'),
                color: Colors.red,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    double panelWidth() =>
        tester.getSize(find.byKey(const Key('panel-pane'))).width;
    final cap = EditSidePanelMetrics.maxAllowed(pageWidth);

    // Far past the cap, in steps, checking every frame of the drag: no rubber
    // band, so the editor is never dragged wider than it is allowed to settle.
    var gesture = await tester.startGesture(
      tester.getCenter(find.byType(ResizablePaneDivider)),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(panelWidth(), lessThanOrEqualTo(cap + 0.01));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(panelWidth(), closeTo(cap, 0.5));
    expect(committed.single, closeTo(cap, 0.5));

    // And the same going the other way, into the minimum.
    committed.clear();
    gesture = await tester.startGesture(
      tester.getCenter(find.byType(ResizablePaneDivider)),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      expect(
        panelWidth(),
        greaterThanOrEqualTo(EditSidePanelMetrics.minWidth - 0.01),
      );
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(panelWidth(), closeTo(EditSidePanelMetrics.minWidth, 0.5));
    expect(committed.single, closeTo(EditSidePanelMetrics.minWidth, 0.5));
  });

  testWidgets('double-tapping the divider resets to the default width', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: EditSidePanelMetrics.duration,
      value: 1,
    );
    addTearDown(controller.dispose);
    Object? committed = 'unset';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 400,
            child: EditSidePanelHost(
              animation: controller,
              listMinWidth: EditSidePanelMetrics.todoListMinWidth,
              storedWidth: 500,
              onWidthCommitted: (width) => committed = width,
              list: const ColoredBox(color: Colors.blue),
              panel: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(ResizablePaneDivider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(ResizablePaneDivider));
    await tester.pumpAndSettle();

    expect(committed, isNull);
  });
}

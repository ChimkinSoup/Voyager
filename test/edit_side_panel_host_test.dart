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
      // Narrow page: keep the default usable under overlay instead of
      // crushing it to the fraction floor.
      expect(
        EditSidePanelMetrics.clampWidth(
          EditSidePanelMetrics.defaultWidth,
          624,
        ),
        EditSidePanelMetrics.defaultWidth,
      );
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

    Future<void> pumpAt(double pageWidth) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: pageWidth,
              height: 400,
              child: EditSidePanelHost(
                animation: controller,
                listMinWidth: EditSidePanelMetrics.todoListMinWidth,
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

    await pumpAt(1100);
    expect(
      tester.getSize(find.byKey(const Key('list-pane'))).width,
      closeTo(1100 - EditSidePanelMetrics.defaultWidth, 1),
    );

    await pumpAt(624);
    // Overlay: the list keeps the full page width under the panel.
    expect(
      tester.getSize(find.byKey(const Key('list-pane'))).width,
      closeTo(624, 1),
    );
    expect(find.byType(ResizablePaneDivider), findsOneWidget);
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

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';

void main() {
  late GaiaSidebar sidebar;
  late VoidCallback toggle;

  Future<void> pumpLayout(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaSidebarLayout(
          sidebar: sidebar,
          side: const SizedBox.expand(key: Key('side')),
          chat: (shown, onToggle) {
            toggle = onToggle;
            return const SizedBox.expand(key: Key('chat body'));
          },
        ),
      ),
    );
  }

  double? sideWidth(WidgetTester tester) {
    final side = find.byKey(const Key('side'));
    return side.evaluate().isEmpty ? null : tester.getSize(side).width;
  }

  double chatWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(const Key('chat body'))).width;

  /// Drags the sidebar's edge by each of [dxs] in turn with the mouse,
  /// without letting go between them.
  Future<void> dragEdge(WidgetTester tester, List<double> dxs) async {
    final gesture = await tester.startGesture(
      Offset(sideWidth(tester)!, 300),
      kind: PointerDeviceKind.mouse,
    );
    for (final dx in dxs) {
      // In steps, as a hand drags, past the drag's slop.
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(dx / 10, 0));
        await tester.pump();
      }
    }
    await gesture.up();
    await tester.pump();
  }

  setUp(() => sidebar = GaiaSidebar());

  testWidgets('toggles in a wide window', (tester) async {
    await pumpLayout(tester, 1200);
    expect(sideWidth(tester), 260);

    toggle();
    await tester.pump();
    expect(sideWidth(tester), isNull);
    expect(chatWidth(tester), 1200);
    expect(sidebar.open, isFalse);

    toggle();
    await tester.pump();
    expect(sideWidth(tester), 260);
  });

  testWidgets('hides when the window narrows, and comes back', (tester) async {
    await pumpLayout(tester, 1200);
    await pumpLayout(tester, 560);
    expect(sideWidth(tester), isNull);
    expect(sidebar.open, isTrue);

    await pumpLayout(tester, 1200);
    expect(sideWidth(tester), 260);
  });

  testWidgets('shrinks before it hides', (tester) async {
    sidebar.width = 400;
    await pumpLayout(tester, 700);
    expect(chatWidth(tester), greaterThanOrEqualTo(400));
    expect(sideWidth(tester), lessThan(400));
  });

  testWidgets('opened in a narrow window, it squeezes the chat', (
    tester,
  ) async {
    sidebar.width = 420;
    await pumpLayout(tester, 560);
    toggle();
    await tester.pump();
    expect(sideWidth(tester), isNotNull);
    expect(chatWidth(tester), greaterThanOrEqualTo(300));

    // Widened and narrowed again, it hides by itself once more.
    await pumpLayout(tester, 1200);
    await pumpLayout(tester, 560);
    expect(sideWidth(tester), isNull);
  });

  testWidgets('a toggle from the window being too narrow closes it', (
    tester,
  ) async {
    await pumpLayout(tester, 560);
    toggle();
    await tester.pump();
    toggle();
    await tester.pump();
    expect(sidebar.open, isFalse);
    await pumpLayout(tester, 1200);
    expect(sideWidth(tester), isNull);
  });

  testWidgets('its edge drags, within limits', (tester) async {
    await pumpLayout(tester, 1200);
    await dragEdge(tester, [500]);
    expect(sideWidth(tester), kGaiaSidebarMaxWidth);
    expect(sidebar.width, kGaiaSidebarMaxWidth);

    await dragEdge(tester, [-240]);
    expect(sideWidth(tester), kGaiaSidebarMinWidth);
    expect(sidebar.open, isTrue);
  });

  testWidgets('dragged well past its narrowest, it closes', (tester) async {
    await pumpLayout(tester, 1200);
    await dragEdge(tester, [-200]);
    expect(sideWidth(tester), isNull);
    expect(sidebar.open, isFalse);

    // And reopens at the width it had before that drag.
    toggle();
    await tester.pump();
    expect(sideWidth(tester), 260);
  });

  testWidgets('closed by a drag while shrunk, it keeps its own width', (
    tester,
  ) async {
    sidebar.width = 400;
    await pumpLayout(tester, 700);
    await dragEdge(tester, [-200]);
    expect(sidebar.open, isFalse);
    expect(sidebar.width, 400);

    await pumpLayout(tester, 1200);
    toggle();
    await tester.pump();
    expect(sideWidth(tester), 400);
  });

  testWidgets('a drag that closes it, dragged back, reopens it', (
    tester,
  ) async {
    await pumpLayout(tester, 1200);
    await dragEdge(tester, [-200, 250]);
    expect(sidebar.open, isTrue);
    expect(sideWidth(tester), greaterThan(kGaiaSidebarMinWidth));
  });

  testWidgets('the chat keeps its state as the sidebar toggles', (
    tester,
  ) async {
    await pumpLayout(tester, 1200);
    final before = tester.element(find.byKey(const Key('chat body')));
    toggle();
    await tester.pump();
    toggle();
    await tester.pump();
    expect(tester.element(find.byKey(const Key('chat body'))), same(before));
  });

  test('keeps its width and whether it is open', () async {
    final dir = await Directory.systemTemp.createTemp('gaia_sidebar');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sidebar.json');

    final first = GaiaSidebar(file: file);
    await first.setWidth(333);
    await first.setOpen(false);

    final second = GaiaSidebar(file: file);
    await second.load();
    expect(second.width, 333);
    expect(second.open, isFalse);
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_zoom.dart';

void main() {
  late GaiaZoomLevel level;
  final content = GlobalKey();

  Future<void> pump(WidgetTester tester) async {
    level = GaiaZoomLevel();
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaZoom(
          level: level,
          child: Focus(autofocus: true, child: SizedBox.expand(key: content)),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  double opacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('Ctrl+Minus lays the chat out in more room, scaled down', (
    tester,
  ) async {
    await pump(tester);
    final full = tester.getSize(find.byKey(content));
    await press(tester, LogicalKeyboardKey.minus);
    expect(level.value, 0.9);
    expect(tester.getSize(find.byKey(content)), full / 0.9);
    // Still fills the window on screen.
    expect(
      tester.getRect(find.byKey(content)).width,
      closeTo(full.width, 0.01),
    );
    await press(tester, LogicalKeyboardKey.equal);
    await press(tester, LogicalKeyboardKey.numpadAdd);
    expect(level.value, 1.1);
    // A German keyboard's +, where US keyboards have ].
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.add,
      physicalKey: PhysicalKeyboardKey.bracketRight,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.add,
      physicalKey: PhysicalKeyboardKey.bracketRight,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(level.value, 1.25);
  });

  testWidgets('above the Navigator, a dialog zooms too and takes the keys', (
    tester,
  ) async {
    level = GaiaZoomLevel();
    final box = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => GaiaZoom(level: level, child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: Focus(
                  autofocus: true,
                  child: SizedBox(key: box, width: 200, height: 100),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final full = tester.getRect(find.byKey(box)).width;
    await press(tester, LogicalKeyboardKey.minus);
    expect(level.value, 0.9);
    expect(tester.getRect(find.byKey(box)).width, closeTo(full * 0.9, 0.01));
  });

  testWidgets('the indicator shows the level, fades, and Reset goes to 100%', (
    tester,
  ) async {
    await pump(tester);
    expect(opacity(tester), 0);
    await press(tester, LogicalKeyboardKey.minus);
    await press(tester, LogicalKeyboardKey.minus);
    expect(find.text('80%'), findsOneWidget);
    expect(opacity(tester), 1);
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(tester), 0);

    // Hovered, it stays until the cursor leaves, and a while after.
    await press(tester, LogicalKeyboardKey.minus);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('75%')));
    await tester.pump(const Duration(seconds: 10));
    expect(opacity(tester), 1);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(tester), 1);
    await mouse.moveTo(tester.getCenter(find.text('Reset')));
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(level.value, 1);
    expect(find.text('100%'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 4));
    expect(opacity(tester), 0);
    await mouse.removePointer();
  });

  testWidgets('Ctrl+0 goes back to 100%, and shows it', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.minus);
    await press(tester, LogicalKeyboardKey.minus);
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(tester), 0);
    await press(tester, LogicalKeyboardKey.digit0);
    expect(level.value, 1);
    expect(find.text('100%'), findsOneWidget);
    expect(opacity(tester), 1);
    await press(tester, LogicalKeyboardKey.equal);
    await press(tester, LogicalKeyboardKey.numpad0);
    expect(level.value, 1);
  });

  testWidgets('Ctrl+scroll zooms instead of scrolling what is under it', (
    tester,
  ) async {
    level = GaiaZoomLevel();
    final list = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaZoom(
          level: level,
          child: ListView(
            controller: list,
            children: [for (var i = 0; i < 100; i++) Text('$i')],
          ),
        ),
      ),
    );
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(100, 300)));
    Future<void> scroll(double dy) async {
      await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      await tester.pump();
    }

    await scroll(100);
    expect(list.offset, 100);
    expect(level.value, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await scroll(100);
    expect(level.value, 0.9);
    await scroll(-100);
    await scroll(-100);
    expect(level.value, 1.1);
    expect(find.text('110%'), findsOneWidget);
    expect(list.offset, 100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('a trackpad pinch steps the zoom, a two-finger scroll does not', (
    tester,
  ) async {
    level = GaiaZoomLevel();
    final list = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaZoom(
          level: level,
          child: ListView(
            controller: list,
            children: [for (var i = 0; i < 100; i++) Text('$i')],
          ),
        ),
      ),
    );
    final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
    const at = Offset(100, 300);
    Future<void> send(PointerEvent event) async {
      await tester.sendEventToBinding(event);
      await tester.pump();
    }

    // A scroll's scale wanders a little; it scrolls and never zooms.
    await send(trackpad.panZoomStart(at));
    await send(
      trackpad.panZoomUpdate(at, pan: const Offset(0, -50), scale: 1.05),
    );
    await send(
      trackpad.panZoomUpdate(at, pan: const Offset(0, -100), scale: 0.95),
    );
    await send(trackpad.panZoomEnd());
    expect(list.offset, greaterThan(0));
    expect(level.value, 1);

    // Spread: one step under 1.15, two past 1.15², and a fast jump at once.
    await send(trackpad.panZoomStart(at));
    await send(trackpad.panZoomUpdate(at, scale: 1.1));
    expect(level.value, 1);
    await send(trackpad.panZoomUpdate(at, scale: 1.2));
    expect(level.value, 1.1);
    expect(find.text('110%'), findsOneWidget);
    await send(trackpad.panZoomUpdate(at, scale: 1.35));
    expect(level.value, 1.25);
    // Closing back past where it stepped steps back down.
    await send(trackpad.panZoomUpdate(at, scale: 1.05));
    expect(level.value, 1.1);
    await send(trackpad.panZoomEnd());

    // Each pinch counts from its own start.
    await send(trackpad.panZoomStart(at));
    await send(trackpad.panZoomUpdate(at, scale: 0.6));
    expect(level.value, 0.8);
    await send(trackpad.panZoomEnd());
  });

  testWidgets('no pinch zoom while something above pinches for itself', (
    tester,
  ) async {
    level = GaiaZoomLevel();
    var pinchable = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaZoom(
          level: level,
          pinchable: () => pinchable,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
    const at = Offset(100, 300);
    Future<void> pinch() async {
      await tester.sendEventToBinding(trackpad.panZoomStart(at));
      await tester.sendEventToBinding(trackpad.panZoomUpdate(at, scale: 1.2));
      await tester.sendEventToBinding(trackpad.panZoomEnd());
      await tester.pump();
    }

    await pinch();
    expect(level.value, 1);
    pinchable = true;
    await pinch();
    expect(level.value, 1.1);
  });

  testWidgets('zoomed out, the far corner still takes clicks', (tester) async {
    level = GaiaZoomLevel();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaZoom(
          level: level,
          child: Align(
            alignment: Alignment.bottomRight,
            child: TextButton(onPressed: () => taps++, child: const Text('x')),
          ),
        ),
      ),
    );
    level.set(0.5);
    await tester.pump();
    await tester.tap(find.text('x'));
    expect(taps, 1);
  });

  testWidgets('held at the ends of the steps', (tester) async {
    await pump(tester);
    for (var i = 0; i < 20; i++) {
      await press(tester, LogicalKeyboardKey.minus);
    }
    expect(level.value, 0.5);
    for (var i = 0; i < 20; i++) {
      await press(tester, LogicalKeyboardKey.equal);
    }
    expect(level.value, 1.5);
  });
}

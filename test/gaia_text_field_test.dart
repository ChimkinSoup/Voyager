import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

import 'narrow_window_harness.dart';

void main() {
  final boundary = GlobalKey();
  late TextEditingController text;
  late FocusNode focus;

  /// Lays the field out again, keeping its text and focus.
  Future<void> buildField(
    WidgetTester tester, {
    Widget? trailing,
    double width = 600,
    int maxLines = 1,
    TextEditingController? controller,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        // Pure red, so the light is easy to tell from the field.
        theme: VoyagerTheme.dark(accent: const Color(0xFFFF0000)),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: RepaintBoundary(
                key: boundary,
                child: GaiaTextField(
                  controller: controller ?? text,
                  focusNode: focus,
                  minLines: 1,
                  maxLines: maxLines,
                  hintText: 'Message Gaia',
                  trailing: trailing,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpField(
    WidgetTester tester, {
    Widget? trailing,
    int maxLines = 1,
  }) async {
    await loadRealFonts(tester);
    text = TextEditingController();
    focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await buildField(tester, trailing: trailing, maxLines: maxLines);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// The field's top edge, as how red each pixel along it is.
  Future<List<int>> topEdge(WidgetTester tester) async {
    final box =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final (width, bytes) = (await tester.runAsync(() async {
      final image = await box.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = image.width;
      image.dispose();
      return (width, data!.buffer.asUint8List());
    }))!;
    final row = Uint8List.sublistView(bytes, 0, width * 4);
    return [
      for (var x = 0; x < width; x++)
        row[x * 4] - [row[x * 4 + 1], row[x * 4 + 2]].reduce(_max),
    ];
  }

  Future<int> brightestX(WidgetTester tester) async {
    final edge = await topEdge(tester);
    var best = 0;
    for (var x = 1; x < edge.length; x++) {
      if (edge[x] > edge[best]) best = x;
    }
    expect(edge[best], greaterThan(60), reason: 'the light should be on');
    return best;
  }

  /// The reddest pixel of the field: the point of its ring nearest the
  /// light.
  Future<(Offset, int)> brightest(WidgetTester tester) async {
    final box =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final (width, bytes) = (await tester.runAsync(() async {
      final image = await box.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = image.width;
      image.dispose();
      return (width, data!.buffer.asUint8List());
    }))!;
    var best = 0;
    var bestRed = -1;
    for (var i = 0; i < bytes.length; i += 4) {
      final red = bytes[i] - _max(bytes[i + 1], bytes[i + 2]);
      if (red > bestRed) (best, bestRed) = (i ~/ 4, red);
    }
    return (
      Offset((best % width).toDouble(), (best ~/ width).toDouble()),
      bestRed,
    );
  }

  /// The caret's centre, in the field's coordinates.
  Offset caret(WidgetTester tester) {
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(text.selection.extent);
    return editable.localToGlobal(caret.center) -
        tester.getTopLeft(find.byType(GaiaTextField));
  }

  /// Expects the light on the caret, or on the field's edge nearest it when
  /// the caret is scrolled out of view: so the ring's brightest pixel is
  /// the ring's nearest to that point.
  Future<void> expectLightOnCaret(WidgetTester tester) async {
    final size = tester.getSize(find.byType(GaiaTextField));
    final at = caret(tester);
    final light = Offset(
      at.dx.clamp(0, size.width),
      at.dy.clamp(0, size.height),
    );
    final edges = {
      Offset(0, light.dy): light.dx,
      Offset(size.width - 1, light.dy): size.width - light.dx,
      Offset(light.dx, 0): light.dy,
      Offset(light.dx, size.height - 1): size.height - light.dy,
    };
    final nearest = edges.entries
        .reduce((a, b) => a.value <= b.value ? a : b)
        .key;
    final (pixel, red) = await brightest(tester);
    expect(red, greaterThan(60), reason: 'the light should be on');
    expect(
      (pixel - nearest).distance,
      lessThan(4),
      reason: 'brightest at $pixel, nearest the caret at $nearest',
    );
  }

  double caretX(WidgetTester tester) {
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(text.selection.extent);
    return editable.localToGlobal(caret.center).dx -
        tester.getTopLeft(find.byType(GaiaTextField)).dx;
  }

  testWidgets(
    'types in Gaia\'s font',
    (tester) async {
      await pumpField(tester);
      final style = tester
          .widget<EditableText>(find.byType(EditableText))
          .style;
      expect(style.fontFamily, AppFonts.family);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the light follows the caret, and the cursor while it moves',
    (tester) async {
      await pumpField(tester);
      expect(
        (await topEdge(tester)).reduce(_max),
        lessThan(20),
        reason: 'no light before focus or hover',
      );

      await tester.enterText(find.byType(EditableText), 'hello');
      await settle(tester);
      expect((await brightestX(tester)).toDouble(), closeTo(caretX(tester), 3));

      await tester.enterText(
        find.byType(EditableText),
        'hello, and then a fair bit further along',
      );
      await settle(tester);
      final typed = caretX(tester);
      expect(typed, greaterThan(200));
      expect((await brightestX(tester)).toDouble(), closeTo(typed, 3));

      // Back to the start of the line without an edit.
      text.selection = const TextSelection.collapsed(offset: 0);
      await settle(tester);
      expect((await brightestX(tester)).toDouble(), closeTo(caretX(tester), 3));

      final field = tester.getTopLeft(find.byType(GaiaTextField));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      // Into the field, already lit at the caret: faded across to the
      // cursor; then moving over the field, on the cursor at once.
      await mouse.moveTo(field + const Offset(450, 20));
      await settle(tester);
      expect((await brightestX(tester)).toDouble(), closeTo(450, 3));
      await mouse.moveTo(field + const Offset(300, 20));
      await tester.pump();
      expect((await brightestX(tester)).toDouble(), closeTo(300, 3));

      // Typing with the cursor still over the field goes back to the caret.
      await tester.enterText(find.byType(EditableText), 'hi');
      await settle(tester);
      expect((await brightestX(tester)).toDouble(), closeTo(caretX(tester), 3));

      await mouse.moveTo(Offset.zero);
      focus.unfocus();
      await settle(tester);
      expect(
        (await topEdge(tester)).reduce(_max),
        lessThan(20),
        reason: 'the light goes out with neither focus nor hover',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a button inside leaves one line as tall as the text makes it',
    (tester) async {
      await pumpField(tester);
      final bare = tester.getSize(find.byType(GaiaTextField)).height;
      await pumpField(
        tester,
        trailing: GaiaButton(
          icon: Icons.arrow_upward,
          size: 32,
          onPressed: () {},
        ),
      );
      expect(tester.getSize(find.byType(GaiaTextField)).height, bare);
      expect(tester.getSize(find.byType(GaiaButton)).height, 32);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a prompt too long for the field scrolls without a bar',
    (tester) async {
      await loadRealFonts(tester);
      final text = TextEditingController(
        text: List.filled(40, 'line').join('\n'),
      );
      final focus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: GaiaTextField(
              controller: text,
              focusNode: focus,
              maxLines: 8,
            ),
          ),
        ),
      );
      expect(find.byType(Scrollable), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is RawScrollbar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'switching between the caret and the cursor fades across, not along',
    (tester) async {
      await pumpField(tester);
      await tester.enterText(find.byType(EditableText), 'hi');
      await settle(tester);
      final caretAt = caretX(tester).round();
      const cursorAt = 450;
      // Between the two, out of both lights' reach.
      const between = 240;
      final full = (await topEdge(tester))[caretAt];
      expect(full, greaterThan(60));

      Future<void> expectMidFade() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        final edge = await topEdge(tester);
        for (final at in [caretAt, cursorAt]) {
          expect(edge[at], inExclusiveRange(10, full - 10), reason: 'at $at');
        }
        expect(edge[between], lessThan(10));
      }

      Future<void> expectLitOnly(int at, int not) async {
        await settle(tester);
        final edge = await topEdge(tester);
        expect(edge[at], greaterThan(full - 15));
        expect(edge[not], lessThan(10));
      }

      final field = tester.getTopLeft(find.byType(GaiaTextField));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      // In: out at the caret, in at the cursor.
      await mouse.moveTo(field + const Offset(450, 20));
      await expectMidFade();
      await expectLitOnly(cursorAt, caretAt);

      // Out: back to the caret the same way.
      await mouse.moveTo(Offset.zero);
      await expectMidFade();
      await expectLitOnly(caretAt, cursorAt);

      // Typing with the cursor over the field fades across too.
      await mouse.moveTo(field + const Offset(450, 20));
      await settle(tester);
      text.selection = const TextSelection.collapsed(offset: 1);
      await expectMidFade();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'unfocused, the light comes and goes at the cursor alone',
    (tester) async {
      await pumpField(tester);
      final field = tester.getTopLeft(find.byType(GaiaTextField));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(field + const Offset(450, 20));
      await settle(tester);
      expect((await brightestX(tester)).toDouble(), closeTo(450, 3));

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final (pixel, red) = await brightest(tester);
      expect(red, greaterThan(10), reason: 'still fading out');
      expect(pixel.dx, closeTo(450, 3), reason: 'where the cursor left it');
      await settle(tester);
      expect((await topEdge(tester)).reduce(_max), lessThan(20));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  group('the light keeps to the caret', () {
    final multiline = List.filled(
      6,
      'the quick brown fox jumps over the lazy dog',
    ).join(' ');

    testWidgets(
      'through a paste that grows and scrolls the field',
      (tester) async {
        await pumpField(tester, maxLines: 8);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => switch (call.method) {
            'Clipboard.getData' => {
              'text': List.filled(20, 'a pasted line').join('\n'),
            },
            'Clipboard.hasStrings' => {'value': true},
            _ => null,
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.enterText(find.byType(EditableText), 'start ');
        await settle(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
        expect(text.text, endsWith('a pasted line'));
        await expectLightOnCaret(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'through edits from code, as Vim or autocorrect make',
      (tester) async {
        await pumpField(tester, maxLines: 8);
        await tester.enterText(find.byType(EditableText), 'teh fox');
        await settle(tester);
        // Autocorrect: a word behind the caret replaced, the caret kept
        // after it.
        text.value = const TextEditingValue(
          text: 'the quick brown fox',
          selection: TextSelection.collapsed(offset: 19),
        );
        await settle(tester);
        await expectLightOnCaret(tester);
        // Vim's visual mode: a selection whose moving end is the caret.
        text.selection = const TextSelection(baseOffset: 19, extentOffset: 4);
        await settle(tester);
        await expectLightOnCaret(tester);
        // A whole new text, caret and all, in one go.
        text.value = TextEditingValue(
          text: multiline,
          selection: TextSelection.collapsed(offset: multiline.length),
        );
        await settle(tester);
        await expectLightOnCaret(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'when the field reflows under it',
      (tester) async {
        await pumpField(tester, maxLines: 8);
        await tester.enterText(find.byType(EditableText), multiline);
        await settle(tester);
        await expectLightOnCaret(tester);
        await buildField(tester, width: 320, maxLines: 8);
        await settle(tester);
        await expectLightOnCaret(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'scrolled out of view, at the edge nearest it',
      (tester) async {
        await pumpField(tester, maxLines: 3);
        await tester.enterText(
          find.byType(EditableText),
          List.filled(12, 'line').join('\n'),
        );
        await settle(tester);
        await expectLightOnCaret(tester);
        tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .jumpTo(0);
        await settle(tester);
        expect(
          caret(tester).dy,
          greaterThan(tester.getSize(find.byType(GaiaTextField)).height),
        );
        await expectLightOnCaret(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'when the field is given a new controller',
      (tester) async {
        await pumpField(tester, maxLines: 8);
        await tester.enterText(find.byType(EditableText), 'old');
        await settle(tester);
        final swapped = TextEditingController();
        addTearDown(swapped.dispose);
        await buildField(tester, maxLines: 8, controller: swapped);
        text = swapped;
        swapped.value = TextEditingValue(
          text: multiline,
          selection: TextSelection.collapsed(offset: multiline.length),
        );
        await settle(tester);
        await expectLightOnCaret(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  testWidgets(
    'a resting cursor keeps the light as the field moves or scrolls under it',
    (tester) async {
      await pumpField(tester, maxLines: 3);
      await tester.enterText(
        find.byType(EditableText),
        List.filled(12, 'line').join('\n'),
      );
      await settle(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      final resting =
          tester.getTopLeft(find.byType(GaiaTextField)) + const Offset(150, 10);
      await mouse.moveTo(resting);
      await settle(tester);

      Future<void> expectUnderCursor() async {
        final at = resting - tester.getTopLeft(find.byType(GaiaTextField));
        final (pixel, red) = await brightest(tester);
        expect(red, greaterThan(60));
        expect((pixel - Offset(at.dx, 0)).distance, lessThan(4));
      }

      await expectUnderCursor();
      // The text scrolls under it, as a wheel would scroll it.
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await settle(tester);
      await expectUnderCursor();
      // The field narrows, and so moves, under it.
      await buildField(tester, width: 500, maxLines: 3);
      await settle(tester);
      await expectUnderCursor();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'clicking the trailing button keeps the focus',
    (tester) async {
      var pressed = 0;
      await pumpField(
        tester,
        trailing: GaiaButton(
          icon: Icons.arrow_upward,
          onPressed: () => pressed++,
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.tap(find.byType(GaiaButton), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(pressed, 1);
      expect(focus.hasFocus, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'keeping up with the caret costs no frames of its own',
    (tester) async {
      await pumpField(tester, maxLines: 8);
      await tester.enterText(find.byType(EditableText), 'hello');
      await settle(tester);
      focus.unfocus();
      await settle(tester);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'its open right-click menu stays as it is while the field rebuilds',
    (tester) async {
      text = TextEditingController(text: 'hello');
      focus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      await buildField(tester);
      await tester.tap(find.byType(TextField), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final menu = tester.state(find.byType(GaiaMenu));

      // The cursor going in and out, and Gaia rebuilding the field.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(TextField)));
      await tester.pump();
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await buildField(tester);
      await tester.pump();

      expect(tester.state(find.byType(GaiaMenu)), same(menu));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

int _max(int a, int b) => a > b ? a : b;

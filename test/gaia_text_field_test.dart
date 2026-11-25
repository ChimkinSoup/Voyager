import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart'
    show voyagerSpellCheckServiceProvider;
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/companion/gaia_aurora_edge.dart';
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

  testWidgets('types in Gaia\'s font', (tester) async {
    await pumpField(tester);
    final style = tester.widget<EditableText>(find.byType(EditableText)).style;
    expect(style.fontFamily, AppFonts.family);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'focused, its edge takes on the accent, and its aurora runs until it blurs',
    (tester) async {
      GaiaAuroraEdge.animate = true;
      addTearDown(() => GaiaAuroraEdge.animate = false);
      await pumpField(tester);
      await settle(tester);
      expect((await brightest(tester)).$2, lessThan(20));
      expect(tester.binding.hasScheduledFrame, isFalse);

      focus.requestFocus();
      await settle(tester);
      expect((await brightest(tester)).$2, greaterThan(40));
      expect(tester.binding.hasScheduledFrame, isTrue);

      focus.unfocus();
      await settle(tester);
      expect((await brightest(tester)).$2, lessThan(20));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a button inside leaves one line as tall as the text makes it', (
    tester,
  ) async {
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
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a prompt too long for the field scrolls without a bar', (
    tester,
  ) async {
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
          body: GaiaTextField(controller: text, focusNode: focus, maxLines: 8),
        ),
      ),
    );
    expect(find.byType(Scrollable), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is RawScrollbar), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the caret stays in view as the field narrows or widens', (
    tester,
  ) async {
    await pumpField(tester, maxLines: 3);
    final long = List.filled(
      12,
      'the quick brown fox jumps over the lazy dog',
    ).join(' ');
    await tester.enterText(find.byType(EditableText), long);
    await settle(tester);

    void expectCaretShown() {
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final rect = editable.getLocalRectForCaret(text.selection.extent);
      expect(rect.top, greaterThanOrEqualTo(-1));
      expect(rect.bottom, lessThanOrEqualTo(editable.size.height + 1));
    }

    expectCaretShown();
    for (final width in [320.0, 600.0, 240.0]) {
      await buildField(tester, width: width, maxLines: 3);
      await settle(tester);
      expectCaretShown();
    }
    // The caret moved up a few lines, then the field widened.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    }
    await settle(tester);
    expect(text.selection.extentOffset, lessThan(long.length));
    expectCaretShown();
    await buildField(tester, width: 400, maxLines: 3);
    await settle(tester);
    expectCaretShown();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  group('long misspelled text scrolled in the field', () {
    const lines = 40;
    const padding = 60.0;

    /// A field in the middle of a [boundary] with [padding] clear around it,
    /// spellchecked, holding [lines] lines of misspellings scrolled to the
    /// middle, with a line's bottom just above the viewport.
    Future<Rect> pumpScrolled(WidgetTester tester) async {
      await loadRealFonts(tester);
      text = TextEditingController(
        text: List.filled(lines, 'zzqxv').join('\n'),
      );
      focus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      final service = VoyagerSpellCheckService()..updateDictionary({'the'});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voyagerSpellCheckServiceProvider.overrideWithValue(service),
          ],
          child: AutocorrectEnabledScope(
            data: AutocorrectScopeData(enabled: false, service: service),
            child: MaterialApp(
              theme: VoyagerTheme.dark(),
              home: Scaffold(
                body: Center(
                  child: RepaintBoundary(
                    key: boundary,
                    child: Padding(
                      padding: const EdgeInsets.all(padding),
                      child: SizedBox(
                        width: 400,
                        child: GaiaTextField(
                          controller: text,
                          focusNode: focus,
                          minLines: 1,
                          maxLines: 4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .jumpTo(editable.preferredLineHeight * lines / 2);
      await tester.pump();
      final size = tester.getSize(find.byType(GaiaTextField));
      return const Offset(padding, padding) & size;
    }

    /// How many pixels of [boundary] pass [test].
    Future<int> countPixels(
      WidgetTester tester,
      bool Function(Offset at, int r, int g, int b) test,
    ) async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final (width, bytes) = (await tester.runAsync(() async {
        final image = await box.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final width = image.width;
        image.dispose();
        return (width, data!.buffer.asUint8List());
      }))!;
      var count = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        final at = Offset(
          (i ~/ 4 % width).toDouble(),
          (i ~/ 4 ~/ width).toDouble(),
        );
        if (test(at, bytes[i], bytes[i + 1], bytes[i + 2])) count++;
      }
      return count;
    }

    // Thin and antialiased, so never full strength.
    bool squiggle(int r, int g, int b) => r > 90 && r > 2 * g && r > 2 * b;

    testWidgets('its underlines stop at the border', (tester) async {
      final field = await pumpScrolled(tester);
      expect(
        await countPixels(
          tester,
          (at, r, g, b) => field.contains(at) && squiggle(r, g, b),
        ),
        greaterThan(0),
        reason: 'the underlines should show inside the field',
      );
      expect(
        await countPixels(
          tester,
          (at, r, g, b) => !field.contains(at) && squiggle(r, g, b),
        ),
        0,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('its letters read up to the border with their underlines', (
      tester,
    ) async {
      final field = await pumpScrolled(tester);
      // The padding above the viewport, inside the field's own edge.
      final strip = Rect.fromLTRB(
        field.left + 2,
        field.top + 3,
        field.right - 2,
        field.top + 8,
      );
      expect(
        await countPixels(
          tester,
          (at, r, g, b) => strip.contains(at) && r > 150 && g > 150 && b > 150,
        ),
        greaterThan(0),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  testWidgets('a pasted Windows line ending comes in as a plain newline', (
    tester,
  ) async {
    await pumpField(tester, maxLines: 8);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => {'text': 'one\r\ntwo'},
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
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(text.text, 'one\ntwo');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'text set from code shows its caret, as a chat switched to has it',
    (tester) async {
      await pumpField(tester, maxLines: 4);
      final long = List.filled(30, 'line').join('\n');
      text.value = TextEditingValue(
        text: long,
        selection: TextSelection.collapsed(offset: long.length),
      );
      await tester.pump();
      await tester.pump();
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      expect(
        editable.getLocalRectForCaret(text.selection.extent).bottom,
        lessThanOrEqualTo(editable.size.height + 1),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('clicking the trailing button keeps the focus', (tester) async {
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
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('keeping up with the caret costs no frames of its own', (
    tester,
  ) async {
    await pumpField(tester, maxLines: 8);
    await tester.enterText(find.byType(EditableText), 'hello');
    await settle(tester);
    focus.unfocus();
    await settle(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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

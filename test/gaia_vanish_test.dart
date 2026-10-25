import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';

import 'narrow_window_harness.dart';

void main() {
  final boundary = GlobalKey();
  final vanish = GlobalKey<GaiaVanishState>();
  late TextEditingController text;

  Future<void> pumpField(WidgetTester tester) async {
    await loadRealFonts(tester);
    text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: RepaintBoundary(
                key: boundary,
                child: GaiaVanish(
                  key: vanish,
                  controller: text,
                  builder: (context, vanishing) => TextField(
                    controller: text,
                    minLines: vanishing ? null : 1,
                    maxLines: vanishing ? null : 8,
                    expands: vanishing,
                    textAlignVertical: vanishing ? TextAlignVertical.top : null,
                    decoration: InputDecoration(
                      hintText: vanishing ? null : 'Message Gaia',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List> snapshot(WidgetTester tester) async {
    final box =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await box.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
  }

  /// Pixels whose channels differ by more than a rounding error.
  int differing(Uint8List a, Uint8List b) {
    expect(a.length, b.length);
    var count = 0;
    for (var i = 0; i < a.length; i += 4) {
      for (var c = 0; c < 4; c++) {
        if ((a[i + c] - b[i + c]).abs() > 8) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  void send() {
    vanish.currentState!.vanish();
    text.clear();
  }

  Future<void> sampleAndRun(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Finder overlay() => find.descendant(
    of: find.byType(GaiaVanish),
    matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring),
  );

  testWidgets(
    'the vanishing text sits exactly where the field drew it, then clears',
    (tester) async {
      await pumpField(tester);
      final oneLine = tester.getSize(find.byType(TextField)).height;
      text.text =
          'Summarise the open pull requests and flag any that touch the sync '
          'worker, then draft release notes for whatever has merged since Friday';
      await tester.pump();
      final tall = tester.getSize(find.byType(TextField)).height;
      expect(tall, greaterThan(oneLine));
      final before = await snapshot(tester);

      send();
      await tester.pump();
      expect(text.text, isEmpty);
      expect(tester.getSize(find.byType(TextField)).height, tall);
      expect(differing(before, await snapshot(tester)), 0);

      // The field closes while particles are still settling, never grows
      // back, and lands on its natural one-line height without a snap.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      var lastHeight = tall;
      var closedWhileShowing = false;
      while (overlay().evaluate().isNotEmpty) {
        await tester.pump(const Duration(milliseconds: 16));
        final height = tester.getSize(find.byType(TextField)).height;
        expect(height, lessThanOrEqualTo(lastHeight));
        if (height < tall && overlay().evaluate().isNotEmpty) {
          closedWhileShowing = true;
        }
        lastHeight = height;
      }
      expect(closedWhileShowing, isTrue);
      expect(lastHeight, oneLine);
      await tester.pump();
      expect(tester.getSize(find.byType(TextField)).height, oneLine);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'text scrolled inside the field vanishes from where it was scrolled to',
    (tester) async {
      await pumpField(tester);
      text.text = [for (var i = 1; i <= 14; i++) 'line $i'].join('\n');
      await tester.pump();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      final before = await snapshot(tester);

      send();
      await tester.pump();
      expect(differing(before, await snapshot(tester)), 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'particles take over from the right while the left still reads',
    (tester) async {
      await pumpField(tester);
      final blank = await snapshot(tester);
      text.text = 'Draft the release notes';
      await tester.pump();
      final full = await snapshot(tester);

      send();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final midway = await snapshot(tester);
      expect(overlay(), findsOneWidget);
      expect(differing(blank, midway), greaterThan(0));
      expect(differing(full, midway), greaterThan(0));

      await sampleAndRun(tester);
      expect(differing(blank, await snapshot(tester)), 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'typing during the effect fades it out at once',
    (tester) async {
      await pumpField(tester);
      text.text = 'First prompt';
      await tester.pump();
      send();
      await tester.pump();
      expect(overlay(), findsOneWidget);

      text.text = 'n';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(overlay(), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'reduced motion skips the effect',
    (tester) async {
      await pumpField(tester);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      text.text = 'First prompt';
      await tester.pump();
      send();
      await tester.pump();
      expect(overlay(), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

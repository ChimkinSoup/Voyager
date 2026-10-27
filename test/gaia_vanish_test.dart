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
    'without a controller, what was built dissolves and closes away',
    (tester) async {
      final images = GlobalKey<GaiaVanishState>();
      var drafted = true;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                child: RepaintBoundary(
                  key: boundary,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setOuter = setState;
                      return GaiaVanish(
                        key: images,
                        refilled: drafted,
                        builder: (context, _) => drafted
                            ? Wrap(
                                spacing: 8,
                                children: [
                                  for (var i = 0; i < 3; i++)
                                    Container(
                                      width: 56,
                                      height: 56,
                                      color: const Color(0xFFE39A5B),
                                    ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final before = await snapshot(tester);

      images.currentState!.vanish();
      setOuter(() => drafted = false);
      await tester.pump();
      expect(tester.getSize(find.byType(GaiaVanish)).height, 56);
      expect(differing(before, await snapshot(tester)), 0);

      // It holds its height until the last particle has gone sideways.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      var closed = false;
      while (overlay().evaluate().isNotEmpty) {
        await tester.pump(const Duration(milliseconds: 16));
        final height = tester.getSize(find.byType(GaiaVanish)).height;
        if (height < 56 && !closed) {
          closed = true;
          final pixels = await snapshot(tester);
          for (var i = 0; i < pixels.length; i += 4) {
            expect(pixels[i + 3], 0, reason: 'a particle as it closes');
          }
        }
      }
      expect(closed, isTrue);
      expect(tester.getSize(find.byType(GaiaVanish)).height, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'vanishing together, one sweep reaches the text only after the images',
    (tester) async {
      await loadRealFonts(tester);
      final images = GlobalKey<GaiaVanishState>();
      text = TextEditingController(text: 'Hi');
      addTearDown(text.dispose);
      var drafted = true;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                child: RepaintBoundary(
                  key: boundary,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setOuter = setState;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          GaiaVanish(
                            key: images,
                            refilled: drafted,
                            builder: (context, _) => drafted
                                ? Container(
                                    height: 40,
                                    color: const Color(0xFFE39A5B),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          GaiaVanish(
                            key: vanish,
                            controller: text,
                            builder: (context, vanishing) =>
                                TextField(controller: text),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final before = await snapshot(tester);
      final field = tester.getRect(find.byType(TextField));
      final fieldRows = (field.top.round(), field.bottom.round());

      /// Pixels differing from [before] within [rows] (top, bottom) and
      /// [columns] (left, right).
      int changedIn(Uint8List now, (int, int) rows, (int, int) columns) {
        var count = 0;
        for (var y = rows.$1; y < rows.$2; y++) {
          for (var x = columns.$1; x < columns.$2; x++) {
            final i = (y * 360 + x) * 4;
            for (var c = 0; c < 4; c++) {
              if ((before[i + c] - now[i + c]).abs() > 8) {
                count++;
                break;
              }
            }
          }
        }
        return count;
      }

      GaiaVanishState.vanishTogether([
        images.currentState!,
        vanish.currentState!,
      ]);
      text.clear();
      setOuter(() => drafted = false);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      // A few steps in: the images' right end is going, the text untouched.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final early = await snapshot(tester);
      expect(changedIn(early, (0, 40), (300, 360)), greaterThan(0));
      // Where "Hi" is (the images' particles wander a little past them).
      expect(changedIn(early, fieldRows, (0, 120)), 0);

      await sampleAndRun(tester);
      expect(overlay(), findsNothing);
      expect(tester.getSize(find.byType(GaiaVanish).first).height, 0);
      expect(text.text, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'behind the sweep, no column of a solid snapshot thins into a seam',
    (tester) async {
      final block = GlobalKey<GaiaVanishState>();
      var drafted = true;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: RepaintBoundary(
                key: boundary,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setOuter = setState;
                    return GaiaVanish(
                      key: block,
                      refilled: drafted,
                      builder: (context, _) => drafted
                          ? Container(
                              height: 200,
                              color: const Color(0xFFE39A5B),
                            )
                          : const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

      block.currentState!.vanish();
      setOuter(() => drafted = false);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final pixels = await snapshot(tester);

      // Each column's share of rows a particle (or the picture) covers.
      // Particles wander, so the walk leaves gaps everywhere; a seam is a
      // column with markedly fewer than its neighbours.
      final shares = [
        for (var x = 0; x < 352; x++)
          [
                for (var y = 2; y < 198; y++)
                  if (pixels[(y * 360 + x) * 4 + 3] > 64) y,
              ].length /
              196,
      ];
      // From where the picture stops.
      final from = shares.indexWhere((share) => share < 1);
      expect(from, greaterThan(0));
      final behind = shares.sublist(from);
      final mean = behind.reduce((a, b) => a + b) / behind.length;
      for (final (x, share) in behind.indexed) {
        expect(share, greaterThan(mean - 0.15), reason: 'column ${from + x}');
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'refilled mid-effect, the new content takes its own height at once',
    (tester) async {
      final images = GlobalKey<GaiaVanishState>();
      var rows = 1;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuter = setState;
                  return GaiaVanish(
                    key: images,
                    refilled: rows > 0,
                    builder: (context, _) => rows == 0
                        ? const SizedBox.shrink()
                        : Container(
                            height: 56.0 * rows,
                            color: const Color(0xFFE39A5B),
                          ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      // Sent, then two rows attached while the first still vanishes.
      images.currentState!.vanish();
      setOuter(() => rows = 0);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      setOuter(() => rows = 2);
      await tester.pump();
      expect(tester.getSize(find.byType(GaiaVanish)).height, 112);
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getSize(find.byType(GaiaVanish)).height, 112);
      await tester.pump(const Duration(milliseconds: 200));
      expect(overlay(), findsNothing);
      expect(tester.getSize(find.byType(GaiaVanish)).height, 112);
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

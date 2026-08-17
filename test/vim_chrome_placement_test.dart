import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_anchored_chrome.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// The two halves of the Vim overlay ride the same [LayerLink] and are held to
/// opposite rules once the field runs out of room.
///
/// The mode badge does nothing: it is part of the field, so it scrolls with it
/// and is cut off wherever the field is cut off. The `/` bar is clamped back
/// into the part of the field still on screen, since a prompt out of sight is
/// no use for the second you are typing into it.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  late ScrollController scrollController;
  final boxKey = GlobalKey(debugLabel: 'scroll box');
  final shotKey = GlobalKey(debugLabel: 'screen shot');

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    scrollController = ScrollController();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
    scrollController.dispose();
  });

  /// Takes focus and presses Escape, which is what puts a field into Normal
  /// mode and so mounts the overlay.
  Future<void> enterNormal(WidgetTester tester) async {
    focusNode.requestFocus();
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  }

  /// A Vim-enabled field, with [decoration] where the height of the box
  /// matters.
  Widget vimField({InputDecoration? decoration}) => VimTextScope(
    enabled: true,
    controller: controller,
    multiline: true,
    builder: (context, vim) => TextField(
      controller: controller,
      focusNode: focusNode,
      maxLines: null,
      cursorColor: vim.overlayCaretColor(Colors.blue),
      cursorWidth: vim.overlayCaretWidth,
      decoration: decoration ?? const InputDecoration(),
    ),
  );

  /// A field inside a [boxHeight]-tall scroller with a button below it, i.e.
  /// the shape of the LeetCode code box. [scrolls] false drops the scroller and
  /// leaves the field unclipped; [atWindowBottom] pushes the box down against
  /// the bottom of the window, like the todo page's composer.
  Future<void> pumpField(
    WidgetTester tester, {
    required String text,
    double boxHeight = 120,
    bool scrolls = true,
    bool atWindowBottom = false,
    Widget? above,
  }) async {
    controller.text = text;
    controller.selection = const TextSelection.collapsed(offset: 0);
    // Roomy on purpose, which puts one line of it at 64px: these tests are
    // about what clipping does to the corner badge, not about the smaller one
    // a short field gets.
    final field = vimField(
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                if (atWindowBottom) const Spacer(),
                SizedBox(
                  key: boxKey,
                  height: boxHeight,
                  child: scrolls
                      ? VoyagerScrollView(
                          controller: scrollController,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [?above, field],
                          ),
                        )
                      : field,
                ),
                if (!atWindowBottom)
                  const SizedBox(
                    height: 60,
                    child: Center(child: Text('Save')),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await enterNormal(tester);
  }

  /// The app's dense composers: a `contentPadding` tight enough that a one-line
  /// box has no room for the full badge.
  const denseDecoration = InputDecoration(
    isDense: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  );

  /// A dense field of an exact [height] and nothing else on screen, for the
  /// rule that turns on how tall the field is.
  Future<void> pumpFieldOfHeight(WidgetTester tester, double height) async {
    controller.text = 'one line';
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: height,
            child: vimField(decoration: denseDecoration),
          ),
        ),
      ),
    );
    await enterNormal(tester);
  }

  /// Padding that keeps even a one-line field above [kVimCompactBadgeField],
  /// so that growing it does not also change which badge it wears.
  const roomyDecoration = InputDecoration(
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 20),
  );

  /// A field left to size itself, so that editing it changes how tall it is.
  Future<void> pumpGrowingField(
    WidgetTester tester, {
    InputDecoration decoration = denseDecoration,
  }) async {
    controller.text = 'one line';
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: vimField(decoration: decoration),
          ),
        ),
      ),
    );
    await enterNormal(tester);
  }

  /// Types [text] into the field the way a `p` does — straight into the
  /// controller, without leaving Normal mode — and gives the frame that grows
  /// the field, and the one after it, a chance to run.
  Future<void> replaceText(WidgetTester tester, String text) async {
    controller.text = text;
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> scrollTo(WidgetTester tester, double pixels) async {
    scrollController.jumpTo(pixels);
    await tester.pump();
    await tester.pump();
  }

  /// Opens the `/` prompt on the field, which is already in Normal mode.
  Future<void> openSearch(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.pump();
  }

  Rect pillRect(WidgetTester tester) => tester.getRect(
    find.ancestor(
      of: find.text('NORMAL'),
      matching: find.byType(DecoratedBox),
    ).first,
  );

  /// The badge's own outline, which the compact form does without.
  BoxBorder? pillBorder(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find.ancestor(
        of: find.text('NORMAL'),
        matching: find.byType(DecoratedBox),
      ).first,
    );
    return (box.decoration as BoxDecoration).border;
  }

  Rect barRect(WidgetTester tester) => tester.getRect(
    find.ancestor(of: find.text('/'), matching: find.byType(DecoratedBox)).first,
  );

  /// What each half of the overlay did on the last paint. The badge is built
  /// first, so it comes first in paint order.
  List<VimChromePlacement> placements(WidgetTester tester) {
    final chromes = tester.allRenderObjects
        .whereType<RenderVimAnchoredChrome>()
        .toList();
    expect(chromes, hasLength(2), reason: 'badge and search bar');
    return [for (final chrome in chromes) chrome.lastPlacement];
  }

  VimChromePlacement badgeAt(WidgetTester tester) => placements(tester).first;
  VimChromePlacement barAt(WidgetTester tester) => placements(tester).last;

  /// The colour actually on screen at [point], which is the only way to prove
  /// something was clipped: a clipped child keeps its size, its position and
  /// its place in the tree, and only stops arriving in the pixels.
  Future<Color> pixelAt(WidgetTester tester, Offset point) async {
    late Color color;
    await tester.runAsync(() async {
      final boundary =
          shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      final i = ((point.dy.round() * image.width) + point.dx.round()) * 4;
      color = Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
      image.dispose();
    });
    return color;
  }

  const longText =
      'l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n'
      'l10\nl11\nl12\nl13\nl14\nl15\nl16\nl17\nl18\nl19\n'
      'l20\nl21\nl22\nl23\nl24\nl25\nl26\nl27\nl28\nl29';

  group('the mode badge', () {
    testWidgets('sits in the field\'s own bottom-right corner', (tester) async {
      await pumpField(tester, text: 'one line', scrolls: false);
      final field = tester.getRect(find.byType(TextField));
      final pill = pillRect(tester);

      expect(pill.right, closeTo(field.right - 10, 0.01));
      expect(pill.bottom, closeTo(field.bottom - 8, 0.01));
      expect(badgeAt(tester), VimChromePlacement.asIs);
    });

    testWidgets('follows the field growing and shrinking under it', (
      tester,
    ) async {
      // A `p` and a `dd` in a box already too tall for the compact badge: the
      // field changes height without changing which badge it wears, so nothing
      // rebuilds the overlay and nothing about the placement changes either.
      // Only the field's own size moved, and [CompositedTransformFollower]
      // reads that when it paints — so without something noticing, the badge
      // hangs where the field's corner used to be.
      await pumpGrowingField(tester, decoration: roomyDecoration);
      final oneLine = tester.getRect(find.byType(TextField));
      expect(pillBorder(tester), isNotNull, reason: 'starts on the full badge');
      expect(pillRect(tester).bottom, closeTo(oneLine.bottom - 8, 0.01));

      await replaceText(tester, 'one line\ntwo\nthree');
      final threeLines = tester.getRect(find.byType(TextField));
      expect(
        threeLines.height,
        greaterThan(oneLine.height),
        reason: 'the paste must have grown the field',
      );
      expect(
        pillBorder(tester),
        isNotNull,
        reason: 'still the full badge, so no rebuild came to the rescue',
      );
      expect(pillRect(tester).bottom, closeTo(threeLines.bottom - 8, 0.01));

      await replaceText(tester, 'one line');
      expect(
        pillRect(tester).bottom,
        closeTo(tester.getRect(find.byType(TextField)).bottom - 8, 0.01),
      );
    });

    testWidgets('rides the field when the box under it scrolls', (tester) async {
      // The LeetCode shape: a field taller than the box it scrolls in. The
      // badge belongs to the field's last line and goes where that line goes —
      // it does not climb back up the box to stay in sight.
      await pumpField(tester, text: longText);
      final box = tester.getRect(find.byKey(boxKey));
      expect(
        tester.getRect(find.byType(TextField)).height,
        greaterThan(box.height),
        reason: 'the field must overflow its box, or this proves nothing',
      );
      final before = pillRect(tester);

      await scrollTo(tester, 200);

      expect(pillRect(tester).top, closeTo(before.top - 200, 0.01));
      final field = tester.getRect(find.byType(TextField));
      expect(pillRect(tester).bottom, closeTo(field.bottom - 8, 0.01));
    });

    testWidgets('is cut off at the box\'s edge, not painted past it', (
      tester,
    ) async {
      // Scrolled so the field straddles the bottom of its box: the badge's top
      // half is inside, its bottom half is over the button below.
      await pumpField(
        tester,
        text: 'one line',
        above: const SizedBox(height: 200),
      );
      await scrollTo(tester, 127);
      final box = tester.getRect(find.byKey(boxKey));
      final pill = pillRect(tester);
      expect(
        pill.top,
        lessThan(box.bottom),
        reason: 'part of the badge must be inside the box',
      );
      expect(
        pill.bottom,
        greaterThan(box.bottom + 2),
        reason: 'and part of it past the edge, or this proves nothing',
      );
      expect(badgeAt(tester).clip, isNotNull);

      final inside = await pixelAt(tester, Offset(pill.center.dx, box.bottom - 3));
      final past = await pixelAt(tester, Offset(pill.center.dx, box.bottom + 3));
      final background = await pixelAt(
        tester,
        Offset(pill.center.dx - 100, box.bottom + 3),
      );
      expect(inside, isNot(past), reason: 'the badge is painted inside the box');
      expect(past, background, reason: 'and nothing of it past the edge');
    });

    testWidgets('is gone once the field is out of its box entirely', (
      tester,
    ) async {
      await pumpField(
        tester,
        text: 'one line',
        above: const SizedBox(height: 200),
      );
      expect(
        badgeAt(tester).shift,
        isNull,
        reason: 'the field starts below the box, so nothing should paint',
      );

      await scrollTo(tester, 144);
      expect(badgeAt(tester).shift, isNotNull);
    });
  });

  group('the mode badge on a short field', () {
    testWidgets('is centred on it rather than tucked into the corner', (
      tester,
    ) async {
      // A dense one-line box: the quick-reminder composer, a bucket-list row.
      // The full badge would sit 8px off the bottom of this and so several
      // pixels below the middle, which is what reads as crooked.
      await pumpFieldOfHeight(tester, 40);
      final field = tester.getRect(find.byType(TextField));
      final pill = pillRect(tester);

      expect(field.height, 40, reason: 'the field must be short');
      expect(pill.center.dy, closeTo(field.center.dy, 0.01));
      expect(pill.right, closeTo(field.right - 10, 0.01));
      expect(badgeAt(tester), VimChromePlacement.asIs);
    });

    testWidgets('is smaller and unbordered, and the full one comes back as '
        'soon as there is room', (tester) async {
      await pumpFieldOfHeight(tester, 40);
      final small = pillRect(tester);
      expect(pillBorder(tester), isNull);

      await pumpFieldOfHeight(tester, 56);
      final full = pillRect(tester);
      final field = tester.getRect(find.byType(TextField));

      expect(pillBorder(tester), isNotNull);
      expect(small.height, lessThan(full.height));
      expect(small.width, lessThan(full.width));
      expect(
        full.bottom,
        closeTo(field.bottom - 8, 0.01),
        reason: 'a roomy field keeps the badge in its bottom-right corner',
      );
    });

    testWidgets('swaps over on its own when the field grows under it', (
      tester,
    ) async {
      // `p` pastes two lines into a one-line box without leaving Normal mode,
      // so nothing rebuilds the overlay: the chrome has to notice the field
      // changing height by itself, or the small centred badge is left floating
      // in the middle of three lines of text.
      await pumpGrowingField(tester);
      expect(pillBorder(tester), isNull);
      final short = tester.getRect(find.byType(TextField)).height;

      controller.text = 'one line\ntwo\nthree';
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        tester.getRect(find.byType(TextField)).height,
        greaterThan(short),
        reason: 'the paste must have grown the field, or this proves nothing',
      );
      expect(pillBorder(tester), isNotNull);
      final field = tester.getRect(find.byType(TextField));
      expect(pillRect(tester).bottom, closeTo(field.bottom - 8, 0.01));
    });
  });

  group('the / bar', () {
    testWidgets('under a field taller than its box hangs off the box', (
      tester,
    ) async {
      await pumpField(tester, text: longText);
      await openSearch(tester);

      final box = tester.getRect(find.byKey(boxKey));
      // The 6px dock below the *visible* bottom of the field, not below the
      // document's — which is far below the screen.
      expect(barRect(tester).top, closeTo(box.bottom + 6, 0.01));
    });

    testWidgets('stays pinned to that box while it scrolls', (tester) async {
      await pumpField(tester, text: longText);
      await openSearch(tester);
      final before = barRect(tester);

      await scrollTo(tester, 200);

      expect(barRect(tester), before);
      expect(barAt(tester).shift, isNot(Offset.zero));
    });

    testWidgets('is dropped once the field leaves its list', (tester) async {
      await pumpField(
        tester,
        text: 'one line',
        above: const SizedBox(height: 40),
      );
      await openSearch(tester);
      expect(barAt(tester).shift, isNotNull);

      await scrollTo(tester, 400);
      expect(barAt(tester).shift, isNull);

      await scrollTo(tester, 0);
      expect(barAt(tester).shift, isNotNull);
    });

    testWidgets('under an unclipped field is left where the link puts it', (
      tester,
    ) async {
      await pumpField(tester, text: 'one line', scrolls: false);
      await openSearch(tester);
      expect(barAt(tester), VimChromePlacement.asIs);
    });

    testWidgets('under the last field on screen stays on screen', (
      tester,
    ) async {
      // The todo composer's shape: nothing under the box but the window edge,
      // so the bar's 6px drop takes it clean off the bottom.
      await pumpField(
        tester,
        text: 'one line',
        boxHeight: 90,
        scrolls: false,
        atWindowBottom: true,
      );
      await openSearch(tester);
      final window = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(
        tester.getRect(find.byType(TextField)).bottom,
        closeTo(window.height, 1),
        reason: 'the field must reach the window edge, or this proves nothing',
      );

      expect(barAt(tester).shift!.dy, lessThan(0));
      expect(barRect(tester).bottom, lessThanOrEqualTo(window.height));
    });
  });
}

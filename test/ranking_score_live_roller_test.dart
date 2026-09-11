// The four things the score rollers were asked for: a draft that is visible on
// the surface behind the popover, a wheel a mouse can grab, a text box whose
// corners are not filled in, and a number that sits against its stars.
//
// Everything here is about what is *shown* mid-gesture. What is written when
// the popover closes is `ranking_score_popover_test.dart`'s job.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/voyager_number_wheel.dart';
import 'package:voyager/core/widgets/voyager_spinner_wheel.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';

/// How full every star in the strip currently is, left to right.
///
/// The fill lives in a clipper rather than in a colour, so this reads the
/// clippers: it is the only place the fraction actually is.
List<double> _starFills(WidgetTester tester) => tester
    .widgetList<ClipRect>(
      find.descendant(
        of: find.byType(RankingStars),
        matching: find.byType(ClipRect),
      ),
    )
    .map((clip) => clip.clipper!.getClip(const Size(1, 1)).width)
    .toList();

/// One notch of a Windows mouse wheel: the OS reports three lines and the
/// embedder is worth twenty pixels a line. Against a 32px roller row that is
/// 1.875 items, which [FixedExtentScrollPhysics] used to snap to two.
const _notch = 60.0;

Future<void> _notchOver(WidgetTester tester, Finder target, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(tester.getCenter(target));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pumpAndSettle();
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 420, child: child)),
  ),
);

void main() {
  group('Live draft', () {
    testWidgets('the stars behind the popover fill as a roller scrolls', (
      tester,
    ) async {
      // Unscored, so the live draft is watched from the midpoint the popover
      // starts an unscored surface on.
      double? saved;
      var savedCount = 0;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => RankingOverallRow(
              value: saved,
              scoreMax: 10,
              precision: RankingScorePrecision.tenths,
              accentColor: Colors.deepPurple,
              label: 'Overall',
              onChanged: (score) => setState(() {
                saved = score;
                savedCount++;
              }),
            ),
          ),
        ),
      );

      expect(_starFills(tester).where((f) => f == 1).length, 0);

      await tester.tap(find.text(rankingUnscoredLabel));
      await tester.pumpAndSettle();
      expect(find.byType(RankingScorePopover), findsOneWidget);

      // The popover starts an unscored surface on the midpoint, so two items
      // up the whole-number roller is 5 -> 7.
      await tester.drag(
        find
            .descendant(
              of: find.byType(RankingScorePopover),
              matching: find.byType(VoyagerSpinnerWheel),
            )
            .first,
        const Offset(0, -64),
      );
      await tester.pump();

      // The strip and the number under the popover have both moved, and
      // nothing has been written yet.
      expect(_starFills(tester).where((f) => f == 1).length, 7);
      expect(savedCount, 0);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(saved, 7.0);
      expect(_starFills(tester).where((f) => f == 1).length, 7);
    });

    testWidgets('escaping puts the stars back where they were', (tester) async {
      await tester.pumpWidget(
        _host(
          const RankingOverallRow(
            value: null,
            scoreMax: 10,
            precision: RankingScorePrecision.tenths,
            accentColor: Colors.deepPurple,
            label: 'Overall',
            onChanged: _ignore,
          ),
        ),
      );

      await tester.tap(find.text(rankingUnscoredLabel));
      await tester.pumpAndSettle();
      await tester.drag(
        find
            .descendant(
              of: find.byType(RankingScorePopover),
              matching: find.byType(VoyagerSpinnerWheel),
            )
            .first,
        const Offset(0, -64),
      );
      await tester.pump();
      expect(_starFills(tester).where((f) => f == 1).length, 7);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_starFills(tester).where((f) => f == 1).length, 0);
    });
  });

  group('Held until saved', () {
    // Every save in the app is async: the stored score only moves some frames
    // after the popover closes. Each test here walks those frames one at a
    // time, because the frame between the close and the landing is the bug.
    const saveDelay = Duration(milliseconds: 100);
    const frame = Duration(milliseconds: 16);

    Widget slowlySavedRow({required double? initial, List<double?>? writes}) {
      var stored = initial;
      return _host(
        StatefulBuilder(
          builder: (context, setState) => RankingOverallRow(
            value: stored,
            scoreMax: 10,
            precision: RankingScorePrecision.tenths,
            accentColor: Colors.deepPurple,
            label: 'Overall',
            onChanged: (score) {
              writes?.add(score);
              Future<void>.delayed(saveDelay, () => setState(() => stored = score));
            },
          ),
        ),
      );
    }

    String number(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byType(RankingScoreNumber),
            matching: find.byType(Text),
          ),
        )
        .data!;

    Future<List<String>> framesUntilSaved(WidgetTester tester) async {
      final seen = <String>[];
      for (var t = Duration.zero; t < saveDelay * 2; t += frame) {
        await tester.pump(frame);
        seen.add(number(tester));
      }
      return seen;
    }

    testWidgets('a written score stays up until its save lands', (
      tester,
    ) async {
      await tester.pumpWidget(slowlySavedRow(initial: null));
      await tester.tap(find.text(rankingUnscoredLabel));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(RankingScorePopover),
          matching: find.byType(TextField),
        ),
        '7',
      );
      await tester.pump();
      expect(number(tester), '7');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(await framesUntilSaved(tester), everyElement('7'));
    });

    testWidgets('a written clear stays clear until its save lands', (
      tester,
    ) async {
      await tester.pumpWidget(slowlySavedRow(initial: 8.4));
      await tester.tap(find.text('8.4'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Clear score'));
      // The press draws one frame before the popover closes. From the close
      // on, the number reads clear and stays that way.
      final frames = await framesUntilSaved(tester);
      expect(frames.first, '8.4');
      expect(frames.skip(1), everyElement(rankingUnscoredLabel));
    });

    testWidgets('two quick wheel notches both count, and never step back', (
      tester,
    ) async {
      final writes = <double?>[];
      await tester.pumpWidget(slowlySavedRow(initial: 5, writes: writes));

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(RankingScoreNumber))),
      );
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -50)));
      await tester.pump();
      // The second notch arrives before the first save has landed.
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -50)));

      final frames = await framesUntilSaved(tester);
      expect(writes, [5.1, 5.2]);
      expect(frames, everyElement('5.2'));
    });
  });

  group('Mouse drag', () {
    testWidgets('a spinner wheel can be dragged with the mouse', (
      tester,
    ) async {
      final controller = FixedExtentScrollController(initialItem: 5);
      addTearDown(controller.dispose);
      var selected = 5;

      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 96,
            child: VoyagerSpinnerWheel(
              controller: controller,
              itemExtent: 32,
              itemCount: 11,
              onSelectedItemChanged: (index) => selected = index,
              itemBuilder: (_, index) => Center(child: Text('$index')),
            ),
          ),
        ),
      );

      await tester.dragFrom(
        tester.getCenter(find.byType(VoyagerSpinnerWheel)),
        const Offset(0, 64),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(selected, 3);
    });

    testWidgets('a number wheel can be dragged with the mouse', (tester) async {
      var selected = 5;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => VoyagerNumberWheel(
              itemCount: 20,
              selectedIndex: selected,
              onSelectedIndexChanged: (index) =>
                  setState(() => selected = index),
              labelForIndex: (index) => '$index',
            ),
          ),
        ),
      );

      await tester.dragFrom(
        tester.getCenter(find.byType(VoyagerNumberWheel)),
        const Offset(0, -88),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(selected, 7);
    });
  });

  group('Mouse notch', () {
    // Every roller here is in half mode, where the decimals column has two
    // slots. A notch worth two items lands back on the digit it started from
    // and carries the whole part instead — 2.5 to 3.5 to 4.5, with the column
    // the pointer is over apparently driving the column beside it.
    Future<List<double>> pumpHalfPopover(
      WidgetTester tester, {
      required double value,
    }) async {
      final drafts = <double>[];
      await tester.pumpWidget(
        _host(
          RankingScorePopover(
            value: value,
            scoreMax: 10,
            precision: RankingScorePrecision.half,
            label: 'Overall',
            onDraftChanged: drafts.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return drafts;
    }

    testWidgets('the decimals roller steps a half, and carries', (
      tester,
    ) async {
      final drafts = await pumpHalfPopover(tester, value: 2.5);
      final decimals = find.byType(VoyagerSpinnerWheel).at(1);

      await _notchOver(tester, decimals, _notch);
      expect(drafts.last, 3.0);
      expect(find.text('3'), findsWidgets);

      await _notchOver(tester, decimals, _notch);
      expect(drafts.last, 3.5);
    });

    testWidgets('the whole-number roller steps a point, skipping nothing', (
      tester,
    ) async {
      final drafts = await pumpHalfPopover(tester, value: 2.5);
      final whole = find.byType(VoyagerSpinnerWheel).first;

      await _notchOver(tester, whole, -_notch);
      expect(drafts.last, 1.5);

      await _notchOver(tester, whole, -_notch);
      expect(drafts.last, 0.5);
    });

    testWidgets('a notch refused at an end changes nothing', (tester) async {
      // A pointer notch at the floor moves no item, and the whole-number
      // roller has no say over the fraction, so `0.5` stays `0.5` (§7.3).
      final drafts = await pumpHalfPopover(tester, value: 0.5);

      await _notchOver(tester, find.byType(VoyagerSpinnerWheel).first, -_notch);
      expect(drafts, isEmpty);
    });

    testWidgets('a number wheel steps one item', (tester) async {
      var selected = 5;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => VoyagerNumberWheel(
              itemCount: 20,
              selectedIndex: selected,
              onSelectedIndexChanged: (index) =>
                  setState(() => selected = index),
              labelForIndex: (index) => '$index',
            ),
          ),
        ),
      );

      await _notchOver(tester, find.byType(VoyagerNumberWheel), _notch);
      expect(selected, 6);
    });

    testWidgets('a bounded wheel reports the notch it cannot take', (
      tester,
    ) async {
      final controller = FixedExtentScrollController();
      addTearDown(controller.dispose);
      final edges = <int>[];
      var selected = 0;

      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 96,
            child: VoyagerSpinnerWheel(
              controller: controller,
              itemExtent: 32,
              itemCount: 11,
              onSelectedItemChanged: (index) => selected = index,
              onEdgeNotch: edges.add,
              itemBuilder: (_, index) => Center(child: Text('$index')),
            ),
          ),
        ),
      );

      await _notchOver(tester, find.byType(VoyagerSpinnerWheel), -_notch);
      expect(edges, [-1]);
      expect(selected, 0);

      await _notchOver(tester, find.byType(VoyagerSpinnerWheel), _notch);
      expect(edges, [-1]);
      expect(selected, 1);
    });
  });

  group('Limits', () {
    // A roller pushed past 0.0 or scoreMax.0 is refusing the move, and has to
    // be seen refusing it: it stretches a little way past the limit and
    // springs back, and the draft never moves. The decimals roller is endless
    // so it can carry, which is why it needs telling where the scale ends.
    Future<List<double>> pumpPopover(
      WidgetTester tester, {
      required double value,
      RankingScorePrecision precision = RankingScorePrecision.tenths,
    }) async {
      final drafts = <double>[];
      await tester.pumpWidget(
        _host(
          RankingScorePopover(
            value: value,
            scoreMax: 10,
            precision: precision,
            label: 'Overall',
            onDraftChanged: drafts.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return drafts;
    }

    Finder wheel(int index) => find.byType(VoyagerSpinnerWheel).at(index);

    double pixels(WidgetTester tester, int index) => tester
        .widget<VoyagerSpinnerWheel>(wheel(index))
        .controller
        .position
        .pixels;

    /// Drags [index] by [dy] and holds it there, returning how far past
    /// [rest] the wheel was pulled before letting go and settling.
    Future<double> stretch(
      WidgetTester tester,
      int index,
      double dy, {
      required double rest,
    }) async {
      final gesture = await tester.startGesture(tester.getCenter(wheel(index)));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(Offset(0, dy / 8));
        await tester.pump();
      }
      final pulled = pixels(tester, index) - rest;
      await gesture.up();
      await tester.pumpAndSettle();
      return pulled;
    }

    testWidgets('the decimals roller prints nothing past the ceiling', (
      tester,
    ) async {
      await pumpPopover(tester, value: 10);
      final digits = find.descendant(of: wheel(1), matching: find.byType(Text));
      final shown = tester.widgetList<Text>(digits).map((t) => t.data);
      // 9.9 is still above it; 10.1 below it is not a score.
      expect(shown, contains('9'));
      expect(shown, isNot(contains('1')));
    });

    testWidgets('the decimals roller prints nothing past the floor', (
      tester,
    ) async {
      await pumpPopover(tester, value: 0);
      final digits = find.descendant(of: wheel(1), matching: find.byType(Text));
      final shown = tester.widgetList<Text>(digits).map((t) => t.data);
      expect(shown, contains('1'));
      expect(shown, isNot(contains('9')));
    });

    for (final precision in [
      RankingScorePrecision.half,
      RankingScorePrecision.tenths,
    ]) {
      testWidgets('${precision.name}: the decimals roller stretches past the '
          'ceiling and springs back', (tester) async {
        final drafts = await pumpPopover(
          tester,
          value: 10,
          precision: precision,
        );
        final rest = pixels(tester, 1);

        // Pulling the wheel up asks for 10.1 / 10.5.
        final pulled = await stretch(tester, 1, -96, rest: rest);
        expect(pulled, greaterThan(0));
        // Never as far as half a row, which would select the row past it.
        expect(pulled, lessThan(16));

        expect(pixels(tester, 1), closeTo(rest, 0.01));
        // Springing back is not a step down: 10.0 does not become 9.9.
        expect(drafts, isEmpty);
      });

      testWidgets('${precision.name}: the decimals roller stretches past the '
          'floor and springs back', (tester) async {
        final drafts = await pumpPopover(
          tester,
          value: 0,
          precision: precision,
        );
        final rest = pixels(tester, 1);

        final pulled = await stretch(tester, 1, 96, rest: rest);
        expect(pulled, lessThan(0));
        expect(pulled, greaterThan(-16));

        expect(pixels(tester, 1), closeTo(rest, 0.01));
        expect(drafts, isEmpty);
      });
    }

    testWidgets('the whole-number roller stretches past its end too', (
      tester,
    ) async {
      final drafts = await pumpPopover(tester, value: 10);
      final rest = pixels(tester, 0);

      final pulled = await stretch(tester, 0, -96, rest: rest);
      expect(pulled, greaterThan(0));
      expect(pulled, lessThan(16));

      expect(pixels(tester, 0), closeTo(rest, 0.01));
      expect(drafts, isEmpty);
    });

    testWidgets('a fling at the ceiling comes to rest on it', (tester) async {
      final drafts = await pumpPopover(tester, value: 9);
      final rest = pixels(tester, 1);

      // Hard enough to carry well past 10.0 if nothing stopped it.
      await tester.fling(wheel(1), const Offset(0, -300), 4000);
      await tester.pumpAndSettle();

      expect(drafts.last, 10.0);
      expect(pixels(tester, 1), closeTo(rest + 10 * 32, 0.01));
    });

    testWidgets('a notch past the ceiling bumps the roller and springs back', (
      tester,
    ) async {
      final drafts = await pumpPopover(tester, value: 10);
      final rest = pixels(tester, 1);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(wheel(1)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(pixels(tester, 1), greaterThan(rest));

      await tester.pumpAndSettle();
      expect(pixels(tester, 1), closeTo(rest, 0.01));
      expect(drafts, isEmpty);
    });

    testWidgets('a notch past the floor bumps the whole-number roller', (
      tester,
    ) async {
      final drafts = await pumpPopover(tester, value: 0);
      final rest = pixels(tester, 0);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(wheel(0)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -_notch)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(pixels(tester, 0), lessThan(rest));

      await tester.pumpAndSettle();
      expect(pixels(tester, 0), closeTo(rest, 0.01));
      expect(drafts, isEmpty);
    });
  });

  testWidgets('a correction that lands mid-drag does not recurse', (
    tester,
  ) async {
    // A jump ends the roller's scroll, and a scroll ending re-syncs the
    // rollers. Run from inside that end notification, the re-sync jumped the
    // held roller again before it had left the scroll, which ended the same
    // scroll again — until the stack overflowed. In the app the field losing
    // focus mid-gesture did it; typing is the same jump.
    await tester.pumpWidget(
      _host(
        const RankingScorePopover(
          value: 5,
          scoreMax: 10,
          precision: RankingScorePrecision.tenths,
          label: 'Overall',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final decimals = find.byType(VoyagerSpinnerWheel).at(1);

    final gesture = await tester.startGesture(tester.getCenter(decimals));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump();

    // Several digits from wherever the drag has the roller, so it jumps.
    final text = tester.widget<TextField>(find.byType(TextField)).controller!;
    text.text = '5.7';
    await tester.pump();
    expect(tester.takeException(), isNull);

    await gesture.up();
    await tester.pumpAndSettle();
    final right = tester.widget<VoyagerSpinnerWheel>(decimals).controller;
    expect(right.selectedItem % 10, 7);
    expect(text.text, '5.7');
  });

  testWidgets('the popover text box paints no fill under its rounded box', (
    tester,
  ) async {
    // A filled InputDecorator paints the fill in the *border's* shape, and the
    // border here is none — a square, which would reach into the corners of
    // the rounded box drawn around the field and cut its curve off.
    await tester.pumpWidget(
      _host(
        const RankingScorePopover(
          value: 3,
          scoreMax: 10,
          precision: RankingScorePrecision.tenths,
          label: 'Overall',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.filled, isFalse);
  });

  testWidgets('the overall number sits against its stars', (tester) async {
    await tester.pumpWidget(
      _host(
        const RankingOverallRow(
          value: 3,
          scoreMax: 10,
          precision: RankingScorePrecision.tenths,
          accentColor: Colors.deepPurple,
          label: 'Overall',
        ),
      ),
    );

    final number = tester.widget<Text>(find.text('3'));
    expect(number.textAlign, TextAlign.right);
  });
}

void _ignore(double? _) {}

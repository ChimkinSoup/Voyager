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
      double? saved = 3;
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

      expect(_starFills(tester).where((f) => f == 1).length, 3);

      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();
      expect(find.byType(RankingScorePopover), findsOneWidget);

      // Two items up the whole-number roller: 3 -> 5.
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
      expect(_starFills(tester).where((f) => f == 1).length, 5);
      expect(savedCount, 0);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(saved, 5.0);
      expect(_starFills(tester).where((f) => f == 1).length, 5);
    });

    testWidgets('escaping puts the stars back where they were', (tester) async {
      await tester.pumpWidget(
        _host(
          const RankingOverallRow(
            value: 3,
            scoreMax: 10,
            precision: RankingScorePrecision.tenths,
            accentColor: Colors.deepPurple,
            label: 'Overall',
            onChanged: _ignore,
          ),
        ),
      );

      await tester.tap(find.text('3'));
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
      expect(_starFills(tester).where((f) => f == 1).length, 5);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_starFills(tester).where((f) => f == 1).length, 3);
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

// The score popover's commit matrix (HLD §7.5) and the gestures on the closed
// number (§6.2). Everything here is about *what is written*, which is the one
// thing the popover does not decide for itself: it hands back an outcome and
// the surface saves from it, so an outcome that says "cancelled" is the whole
// of what "nothing changed" means.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';

/// Hosts one number control and records every score it commits.
///
/// `saved` holds the *writes*: a cancel leaves it untouched, which is exactly
/// the distinction the commit matrix turns on.
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.initial,
    required this.saved,
    this.scoreMax = 10,
    this.precision = RankingScorePrecision.tenths,
  });

  final double? initial;
  final List<double?> saved;
  final int scoreMax;
  final RankingScorePrecision precision;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  double? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: RankingScoreNumber(
            value: _value,
            scoreMax: widget.scoreMax,
            precision: widget.precision,
            label: 'Overall',
            onChanged: (score) {
              widget.saved.add(score);
              setState(() => _value = score);
            },
          ),
        ),
      ),
    );
  }
}

Future<List<double?>> _open(
  WidgetTester tester, {
  double? initial,
  int scoreMax = 10,
  RankingScorePrecision precision = RankingScorePrecision.tenths,
}) async {
  final saved = <double?>[];
  await tester.pumpWidget(
    _Host(
      initial: initial,
      saved: saved,
      scoreMax: scoreMax,
      precision: precision,
    ),
  );
  await tester.tap(find.byType(RankingScoreNumber));
  await tester.pumpAndSettle();
  expect(find.byType(RankingScorePopover), findsOneWidget);
  return saved;
}

Finder get _scoreField => find.descendant(
  of: find.byType(RankingScorePopover),
  matching: find.byType(TextField),
);

/// Taps the barrier well away from the popover, which is the outside click of
/// §7.5 rather than a synthesised pop.
Future<void> _clickOutside(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the number shows a dash until something is scored', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(key: UniqueKey(), initial: null, saved: []));
    expect(find.text(rankingUnscoredLabel), findsOneWidget);

    // A fresh key so the host takes the new value rather than keeping the
    // state it already had.
    await tester.pumpWidget(_Host(key: UniqueKey(), initial: 0, saved: []));
    // A stored zero is a score, and reads as one (§4).
    expect(find.text('0'), findsOneWidget);
    expect(find.text(rankingUnscoredLabel), findsNothing);
  });

  testWidgets('opens on the current value, focused and selected', (
    tester,
  ) async {
    await _open(tester, initial: 8.4);

    final field = tester.widget<TextField>(_scoreField);
    expect(field.controller!.text, '8.4');
    expect(field.focusNode!.hasFocus, isTrue);
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 3),
    );
  });

  testWidgets('an unscored surface opens on the midpoint as a draft', (
    tester,
  ) async {
    final saved = await _open(tester, initial: null);
    expect(tester.widget<TextField>(_scoreField).controller!.text, '5');
    // Shown, not stored: nothing has been written yet.
    expect(saved, isEmpty);
  });

  testWidgets('Esc leaves an unscored surface unscored', (tester) async {
    final saved = await _open(tester, initial: null);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(RankingScorePopover), findsNothing);
    expect(saved, isEmpty);
    expect(find.text(rankingUnscoredLabel), findsOneWidget);
  });

  testWidgets('Esc restores the previous score after an edit', (tester) async {
    final saved = await _open(tester, initial: 8.4);
    await tester.enterText(_scoreField, '3.1');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
    expect(find.text('8.4'), findsOneWidget);
  });

  testWidgets('Enter with nothing touched commits the midpoint', (
    tester,
  ) async {
    final saved = await _open(tester, initial: null);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(saved, [5.0]);
  });

  testWidgets('an outside click with nothing touched commits the midpoint', (
    tester,
  ) async {
    final saved = await _open(tester, initial: null);
    await _clickOutside(tester);

    expect(saved, [5.0]);
  });

  testWidgets('an outside click leaves an untouched score alone', (
    tester,
  ) async {
    final saved = await _open(tester, initial: 8.4);
    await _clickOutside(tester);

    // "Keep same" is a no-op, not a rewrite: committing 8.4 over 8.4 would
    // still bump the row's version and re-sort it by recency.
    expect(saved, isEmpty);
    expect(find.text('8.4'), findsOneWidget);
  });

  testWidgets('an outside click commits what was typed', (tester) async {
    final saved = await _open(tester, initial: 8.4);
    await tester.enterText(_scoreField, '9.7');
    await tester.pump();
    await _clickOutside(tester);

    expect(saved, [9.7]);
  });

  testWidgets('half mode snaps typed tenths on the way out', (tester) async {
    final saved = await _open(
      tester,
      initial: 8,
      precision: RankingScorePrecision.half,
    );
    await tester.enterText(_scoreField, '8.3');
    await tester.pump();
    await _clickOutside(tester);

    expect(saved, [8.5]);
  });

  testWidgets('integer mode drops the fraction and hides the right roller', (
    tester,
  ) async {
    final saved = await _open(
      tester,
      initial: 3,
      precision: RankingScorePrecision.integers,
    );
    // One roller, and no decimal point between two of them.
    expect(
      find.descendant(
        of: find.byType(RankingScorePopover),
        matching: find.byType(ListWheelScrollView),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(RankingScorePopover),
        matching: find.text('.'),
      ),
      findsNothing,
    );

    await tester.enterText(_scoreField, '8.4');
    await tester.pump();
    await _clickOutside(tester);

    expect(saved, [8.0]);
  });

  testWidgets('typing past the ceiling clamps to the scale', (tester) async {
    final saved = await _open(tester, initial: 8.4, scoreMax: 10);
    await tester.enterText(_scoreField, '99');
    await tester.pump();
    await _clickOutside(tester);

    expect(saved, [10.0]);
  });

  testWidgets('Clear writes a null, and closes a never-scored surface', (
    tester,
  ) async {
    var saved = await _open(tester, initial: 8.4);
    await tester.tap(find.byTooltip('Clear score'));
    await tester.pumpAndSettle();
    expect(saved, [null]);
    expect(find.text(rankingUnscoredLabel), findsOneWidget);

    // Nothing to clear when there was never a score: it closes, and writes
    // nothing, rather than stamping a null over a null (§7.5).
    saved = await _open(tester, initial: null);
    await tester.tap(find.byTooltip('Clear score'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
  });

  testWidgets('a second number cannot open a second popover', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final value in [8.4, 2.0]) ...[
                RankingScoreNumber(
                  value: value,
                  scoreMax: 10,
                  precision: RankingScorePrecision.tenths,
                  label: 'Overall',
                  onChanged: (_) {},
                ),
                // Far enough apart that the second number is outside the
                // popover the first one opens, so the tap on it lands on the
                // barrier rather than on the popover's own body.
                const SizedBox(height: 240),
              ],
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(RankingScoreNumber).first);
    await tester.pumpAndSettle();
    expect(find.byType(RankingScorePopover), findsOneWidget);

    // The open popover's barrier takes the tap meant for the other number, so
    // the second one never opens on top of the first (§7.1).
    await tester.tap(find.byType(RankingScoreNumber).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(RankingScorePopover), findsNothing);
  });

  group('Rollers', () {
    /// Drags one roller by [items] whole rows — negative moves the wheel's
    /// values *up*, the way a real flick does.
    Future<void> drag(WidgetTester tester, int wheel, double items) async {
      final finder = find.byType(ListWheelScrollView).at(wheel);
      await tester.drag(finder, Offset(0, -32.0 * items));
      await tester.pumpAndSettle();
    }

    String text(WidgetTester tester) =>
        tester.widget<TextField>(_scoreField).controller!.text;

    testWidgets('the right roller carries into the left', (tester) async {
      await _open(tester, initial: 8.9);
      await drag(tester, 1, 1);
      expect(text(tester), '9');
    });

    testWidgets('rolling below the first digit borrows from the left', (
      tester,
    ) async {
      await _open(tester, initial: 9);
      await drag(tester, 1, -1);
      expect(text(tester), '8.9');
    });

    testWidgets('the ceiling snaps back once the scroll settles', (
      tester,
    ) async {
      final saved = await _open(tester, initial: 10, scoreMax: 10);
      await drag(tester, 1, 1);
      // The roller physically moved past the top and came back: the draft
      // never leaves the scale (§7.3).
      expect(text(tester), '10');
      await _clickOutside(tester);
      expect(saved, isEmpty);
    });

    testWidgets('the floor snaps back once the scroll settles', (tester) async {
      await _open(tester, initial: 0);
      await drag(tester, 1, -1);
      expect(text(tester), '0');
    });

    testWidgets('half mode keeps its fraction when the left roller is pushed '
        'past the floor', (tester) async {
      final saved = await _open(
        tester,
        initial: 0.5,
        precision: RankingScorePrecision.half,
      );
      await drag(tester, 0, -1);
      // The whole-part roller only ever moves the whole part: refused at the
      // floor it changes nothing, and the fraction is not its to drop (§7.3).
      expect(text(tester), '0.5');
      await _clickOutside(tester);
      expect(saved, isEmpty);
    });
  });

  group('Closed number', () {
    testWidgets('the wheel nudges a score by one step and commits', (
      tester,
    ) async {
      final saved = <double?>[];
      await tester.pumpWidget(_Host(initial: 8.4, saved: saved));

      final center = tester.getCenter(find.byType(RankingScoreNumber));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -50)));
      await tester.pump();

      expect(saved, [8.5]);
      expect(find.byType(RankingScorePopover), findsNothing);
    });

    testWidgets('the wheel starts an unscored surface at the midpoint', (
      tester,
    ) async {
      final saved = <double?>[];
      await tester.pumpWidget(_Host(initial: null, saved: saved));

      final center = tester.getCenter(find.byType(RankingScoreNumber));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
      await tester.pump();

      // Down from the midpoint of a ten-point tenths scale.
      expect(saved, [4.9]);
    });

    testWidgets('a long press clears, and does nothing when already clear', (
      tester,
    ) async {
      final saved = <double?>[];
      await tester.pumpWidget(_Host(initial: 8.4, saved: saved));

      await tester.longPress(find.byType(RankingScoreNumber));
      await tester.pumpAndSettle();
      expect(saved, [null]);

      await tester.longPress(find.byType(RankingScoreNumber));
      await tester.pumpAndSettle();
      expect(saved, [null]);
    });
  });
}

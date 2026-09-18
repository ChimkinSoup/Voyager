// The calendar's "Today / Tomorrow / Next Week" row used to be a horizontal
// scroll view, and at the width the date-and-time popover gives the calendar
// (its left half) the chips were wide enough to overflow it — so the top of
// the picker drifted sideways under a wheel or trackpad. This is the check
// that the row both fits and cannot scroll, at every width the popover is
// opened at.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/domain/models/enums.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

/// The left pane of `DateTimeSelectorPopover` — a 500pt popover split 3:2 with
/// a 1pt divider — and the whole of the standalone 320pt date popover.
const _paneWidths = [299.4, 320.0];

const _chipLabels = ['Today', 'Tomorrow', 'Next Week'];

void main() {
  for (final width in _paneWidths) {
    testWidgets('quick-action chips fit ${width}pt without scrolling', (
      tester,
    ) async {
      await loadRealFonts(tester);
      final date = DateTime(2026, 9, 17);

      await tester.pumpWidget(
        MaterialApp(
          theme: VoyagerTheme.forMode(
            AppThemeMode.dark,
            accent: const Color(0xFF7C9EFF),
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: 380,
                child: DateSelectorPopover(
                  initialStartDate: date,
                  initialEndDate: date,
                  singleDateMode: true,
                  inlineMode: true,
                  onDateSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // A row too wide for its pane is a layout overflow.
      expect(tester.takeException(), isNull);

      for (final label in _chipLabels) {
        expect(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
            ),
          ),
          findsNothing,
          reason: 'the chip row must not be horizontally scrollable',
        );

        // Laid out at its natural width, so nothing was squeezed to an
        // ellipsis to make the row fit.
        final text = tester.widget<Text>(find.text(label));
        final painter = TextPainter(
          text: TextSpan(text: label, style: text.style),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        expect(
          tester.getSize(find.text(label)).width,
          closeTo(painter.width, 0.5),
          reason: '"$label" was truncated to fit',
        );
      }
    });
  }
}

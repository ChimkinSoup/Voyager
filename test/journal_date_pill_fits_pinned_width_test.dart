// The journal editor's date pill is pinned to a floor width so the metadata
// row doesn't shift as the selection moves between entries. This is the check
// that the floor is actually wide enough for every label
// `DateFormat.yMMMd() at formatTime12Hour` can produce, so no entry is ever the
// one that pushes past it — see journal_metadata_row_stable_width_test.dart for
// the row holding still, which is what the floor is for.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/domain/models/enums.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

/// `_journalDatePillMinWidth` in journal_page.dart, which is private to it.
const _datePillMinWidth = 200.0;

/// [SelectorPill]'s own horizontal padding, a side, when not `dense`.
const _pillHorizontalPadding = 8.0;

void main() {
  testWidgets('every date-pill label fits the pinned width', (tester) async {
    await loadRealFonts(tester);
    final theme = VoyagerTheme.forMode(
      AppThemeMode.dark,
      accent: const Color(0xFF7C9EFF),
    );
    final style = theme.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w500,
    );

    var widest = 0.0;
    var widestLabel = '';
    for (var month = 1; month <= 12; month++) {
      for (final day in [1, 8, 10, 18, 20, 22, 28]) {
        for (final hour in [1, 8, 10, 11, 12, 13, 20, 22, 23]) {
          for (final minute in [0, 8, 18, 28, 38, 48, 58]) {
            final date = DateTime(2026, month, day, hour, minute);
            final label =
                '${DateFormat.yMMMd().format(date)} at ${formatTime12Hour(date)}';
            final painter = TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: ui.TextDirection.ltr,
              maxLines: 1,
            )..layout();
            if (painter.width > widest) {
              widest = painter.width;
              widestLabel = label;
            }
          }
        }
      }
    }

    expect(
      widest + 2 * _pillHorizontalPadding,
      lessThanOrEqualTo(_datePillMinWidth),
      reason:
          '"$widestLabel" is the widest label and needs '
          '${widest + 2 * _pillHorizontalPadding}px',
    );
  });
}

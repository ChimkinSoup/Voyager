// BUG-182: each page hands the date picker its own accent — on Jobs, the
// company's category colour, or the theme's outline grey for none — but the
// selected day and the selected quick chip were labelled with the theme's
// onPrimary, which is made for the app accent. On the Jobs grey that was dark
// grey on grey. The labels now take their ink from the accent they sit on.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

void main() {
  final themes = {'dark': VoyagerTheme.dark(), 'light': VoyagerTheme.light()};
  for (final MapEntry(key: mode, value: theme) in themes.entries) {
    final accents = {
      // Jobs' fallback for an uncategorised company.
      'outline grey': theme.colorScheme.outline,
      'pastel': const Color(0xFFE8C07A),
      'deep blue': const Color(0xFF1F3A93),
    };
    for (final MapEntry(key: name, value: accent) in accents.entries) {
      testWidgets(
        'BUG-182 today selected on $name, $mode: labels readable',
        (tester) async {
          await loadRealFonts(tester);
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 320,
                    height: 380,
                    child: DateSelectorPopover(
                      initialStartDate: today,
                      initialEndDate: today,
                      singleDateMode: true,
                      inlineMode: true,
                      accentColor: accent,
                      onDateSelected: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          // What the labels actually sit on: opaque, so nothing behind the
          // popover changes it.
          final fill = tester
              .widget<ActionChip>(
                find.ancestor(
                  of: find.text('Today'),
                  matching: find.byType(ActionChip),
                ),
              )
              .backgroundColor!;
          expect(fill.a, 1);
          expect(fill, Color.alphaBlend(accent, theme.colorScheme.surface));

          final chip = tester.widget<Text>(find.text('Today'));
          expect(
            _contrast(chip.style!.color!, fill),
            greaterThanOrEqualTo(4.5),
          );
          // The selected day is the bold one: a day near a month's edge can
          // also show greyed in the neighbouring month.
          final day = tester
              .widgetList<Text>(find.text('${today.day}'))
              .singleWhere((t) => t.style?.fontWeight == FontWeight.bold);
          final disc = tester
              .widgetList<Container>(
                find.ancestor(
                  of: find.byWidget(day),
                  matching: find.byType(Container),
                ),
              )
              .map((c) => c.decoration)
              .whereType<BoxDecoration>()
              .firstWhere((d) => d.shape == BoxShape.circle);
          expect(disc.color, fill);
          expect(_contrast(day.style!.color!, fill), greaterThanOrEqualTo(4.5));
          // Painted with that ink, not overridden further down.
          final paragraph = tester.renderObject<RenderParagraph>(
            find.byWidget(day),
          );
          expect(paragraph.text.style?.color, day.style!.color);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }
}

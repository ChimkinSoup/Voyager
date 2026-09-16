// The editor's metadata row sits above the body box, and its date pill is
// sized by a label whose spelling varies by a character or two from entry to
// entry ("Sep 1, 2026 at 4:20 AM" against "May 10, 2026 at 10:00 AM"). Sized to
// the label, the pill dragged the weather button and the mood slider with it
// every time the selection moved, which read as the row twitching.
//
// Measured with the real font, not the test one: the check is about glyph
// widths, which every glyph being one em wide would make meaningless.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'narrow_window_harness.dart' show loadRealFonts;
import 'support/journal_page_harness.dart';

Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the metadata row holds still across a date-label length change',
    (tester) async {
      await loadRealFonts(tester);
      await pumpJournalPage(
        tester,
        theme: VoyagerTheme.forMode(
          AppThemeMode.dark,
          accent: const Color(0xFF7C9EFF),
        ),
        seedEntries: (now) => [
          // The two extremes of the label: a one-digit day at a one-digit hour,
          // and the widest the formatter can produce.
          JournalEntry(
            id: 'short-label',
            journalId: journalHarnessId,
            title: 'Short label',
            body: '',
            entryDate: DateTime(2026, 9, 1, 4, 20),
            timestamp: now,
            createdAt: now,
            updatedAt: now,
          ),
          JournalEntry(
            id: 'long-label',
            journalId: journalHarnessId,
            title: 'Long label',
            body: '',
            entryDate: DateTime(2026, 5, 10, 10, 0),
            timestamp: now,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );

      Finder row(String title) => find.descendant(
        of: find.byType(KeepAliveScrollList),
        matching: find.text(title),
      );
      // The mood slider's right edge and the date pill's own box together cover
      // every control between them.
      ({Rect slider, Size pill}) geometry() => (
        slider: tester.getRect(find.byType(MoodGradientSlider)),
        pill: tester.getSize(find.byType(SelectorPill)),
      );

      await tester.tap(row('Short label'));
      await settle(tester);
      final short = geometry();

      await tester.tap(row('Long label'));
      await settle(tester);

      expect(geometry(), short);

      await disposeJournalPage(tester);
    },
  );
}

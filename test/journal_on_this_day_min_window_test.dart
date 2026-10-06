// At the minimum window size the editor's metadata row stacks the mood slider
// on a line of its own, running to the editor's right edge, and the tucked
// On this day strip covered its last stop and part of the trash button
// (BUG-055).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/journal_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the tucked strip leaves the mood slider and trash uncovered', (
    tester,
  ) async {
    // The journal page's share of the 720×520 minimum window, beside the rail.
    tester.view.physicalSize = const Size(630, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpJournalPage(
      tester,
      configureJournal: (journal) =>
          journal.copyWith(onThisDayCadence: OnThisDayCadence.yearly),
      seedEntries: (now) {
        final local = DateTime.now();
        final yearAgo = DateTime(
          local.year - 1,
          local.month,
          local.day,
          12,
        ).toUtc();
        return [
          for (final (id, date) in [('today', now), ('year-ago', yearAgo)])
            JournalEntry(
              id: id,
              journalId: journalHarnessId,
              title: 'Entry $id',
              body: '',
              entryDate: date,
              timestamp: date,
              createdAt: date,
              updatedAt: date,
            ),
        ];
      },
    );
    // Past the auto-expand, then tucked again by a click outside the card.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.tapAt(const Offset(10, 300));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // The strip's icon is the last of the two history icons (the card's
    // hidden header holds the other), centred in the strip.
    final stripIcon = find.byIcon(PhosphorIconsRegular.clockCounterClockwise);
    expect(stripIcon, findsNWidgets(2));
    final stripLeft = tester.getCenter(stripIcon.last).dx - 12;

    final slider = tester.getRect(find.byType(MoodGradientSlider));
    final trash = tester.getRect(find.byTooltip('Delete entry'));
    expect(trash.top, greaterThanOrEqualTo(slider.bottom), reason: 'stacked');
    expect(slider.right, lessThanOrEqualTo(stripLeft));
    expect(trash.right, lessThanOrEqualTo(stripLeft));

    await disposeJournalPage(tester);
  });
}

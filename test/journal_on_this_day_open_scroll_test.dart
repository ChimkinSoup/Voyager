// Opening an On this day memory scrolls the entry list to it
// (ON_THIS_DAY_HLD.md §5.4). A memory is a year back, far below the rows on
// screen, so without the scroll the list shows nothing selected.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/on_this_day_overlay.dart';

import 'support/journal_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  for (final showAll in [true, false]) {
    testWidgets('Open scrolls the list to the memory '
        '(${showAll ? 'All journals' : 'one journal'})', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final local = DateTime.now();
      final yearAgo = DateTime(local.year - 1, local.month, local.day, 12);
      await pumpJournalPage(
        tester,
        showAllJournals: showAll,
        configureJournal: (j) =>
            j.copyWith(onThisDayCadence: OnThisDayCadence.yearly),
        seedEntries: (now) => [
          for (var i = 0; i < 60; i++)
            JournalEntry(
              id: 'recent-$i',
              journalId: journalHarnessId,
              title: 'Recent $i',
              // Mixed row heights: every other row has a preview line.
              body: i.isEven ? 'A first sentence for the preview.' : '',
              entryDate: now.subtract(Duration(hours: i + 1)),
              timestamp: now.subtract(Duration(hours: i + 1)),
              createdAt: now,
              updatedAt: now,
            ),
          JournalEntry(
            id: 'memory',
            journalId: journalHarnessId,
            title: 'Tester memory',
            body: 'From a year ago',
            entryDate: yearAgo.toUtc(),
            timestamp: yearAgo.toUtc(),
            createdAt: yearAgo.toUtc(),
            updatedAt: yearAgo.toUtc(),
          ),
        ],
      );
      await tester.pump(OnThisDayOverlay.entranceDelay);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      await tester.tap(find.text('Open'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      // The list row (keyed by entry id), not the editor or the card.
      // Each row carries its key twice (KeyedSubtree and its row).
      final row = find.byKey(const ValueKey('memory')).first;
      expect(row, findsOneWidget, reason: 'row built, so scrolled near it');
      final rect = tester.getRect(row);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(900));
      await disposeJournalPage(tester);
    });
  }
}

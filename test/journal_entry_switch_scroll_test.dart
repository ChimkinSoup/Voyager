// The body editor is one widget reused across entries, and switching entries
// only swapped its text: the next entry opened at the previous one's scroll
// offset, clamped to its own length. Each entry now opens at the top.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/journal_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('switching entries opens the next one at the top', (
    tester,
  ) async {
    final longBody = List.generate(200, (i) => 'Line $i').join('\n');
    JournalEntry entry(String id, String title, DateTime date) => JournalEntry(
      id: id,
      journalId: journalHarnessId,
      title: title,
      body: longBody,
      entryDate: date,
      timestamp: date,
      createdAt: date,
      updatedAt: date,
    );

    await pumpJournalPage(
      tester,
      seedEntries: (now) => [
        entry('entry-a', 'First entry', now),
        entry('entry-b', 'Second entry', now.subtract(const Duration(days: 1))),
      ],
    );

    ScrollPosition bodyScroll() => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byWidgetPredicate(
                  (w) => w is TagHighlightedTextField && w.expands,
                ),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    // The newest entry opens on its own.
    expect(find.widgetWithText(TextField, 'First entry'), findsOneWidget);
    final scroll = bodyScroll();
    expect(scroll.maxScrollExtent, greaterThan(0));
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pump();

    await tester.tap(find.text('Second entry'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(bodyScroll().pixels, 0);

    await disposeJournalPage(tester);
  });
}

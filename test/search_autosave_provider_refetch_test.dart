// Guards the cost of the Search entry dialog's autosave, as
// journal_autosave_provider_refetch_test.dart does for the Journal page.
//
// Each autosave used to hand its row to the page behind the dialog, which
// rebuilt the results list and invalidated every keepAlive journal entry
// provider — re-reading the whole entries table on every pause in typing.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/counting_journal_repository.dart';
import 'support/search_page_harness.dart';

List<JournalEntry> _seed(DateTime now) => [
  JournalEntry(
    id: 'search-entry',
    journalId: searchHarnessJournalId,
    title: 'Seeded title',
    body: 'Seeded body',
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  ),
];

Finder _titleField() => find
    .descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(EditableText),
    )
    .first;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('autosaving does not re-read the entries table', (tester) async {
    late CountingJournalRepository repo;
    final db = await pumpSearchPage(
      tester,
      entries: _seed,
      extraOverrides: [
        journalRepositoryProvider.overrideWith((ref) {
          return repo = CountingJournalRepository(
            DriftJournalRepository(ref.watch(databaseProvider)),
          );
        }),
      ],
    );

    await tester.tap(find.text('Seeded title'));
    await settle(tester);
    repo.resetCounts();

    // Three bursts, each followed by a pause long enough to autosave.
    for (final text in const ['one', 'one two', 'one two three']) {
      await tester.enterText(_titleField(), text);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    }

    expect(
      (await DriftJournalRepository(db).getEntry('search-entry'))?.title,
      'one two three',
      reason: 'skipping the refresh must not skip the save',
    );
    expect(
      repo.tableScans,
      0,
      reason:
          'an autosave changes only the open row, which the dialog already '
          'shows. Saw listEntries=${repo.listEntriesCalls} '
          'getAllEntries=${repo.getAllEntriesCalls} '
          'countEntries=${repo.countEntriesCalls}.',
    );

    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(
      repo.listEntriesCalls,
      greaterThan(0),
      reason: 'closing the dialog should refresh the entry lists',
    );
    expect(find.text('one two three'), findsOneWidget);

    await disposeSearchPage(tester);
  });
}

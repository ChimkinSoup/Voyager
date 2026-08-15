// The counterpart to todo_all_tasks_destination_test.dart. The journal page
// used to record the all-journals view by overwriting the last-viewed id with
// a sentinel, so reopening into that view filed new entries under the default
// journal instead of the one that was actually open.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('restores the all-journals view across a restart', (
    tester,
  ) async {
    await pumpJournalPage(tester, showAllJournals: true);

    expect(find.text('All journals'), findsOneWidget);
    await disposeJournalPage(tester);
  });

  testWidgets('an entry added from the all-journals view goes to the last '
      'journal', (tester) async {
    final db = await pumpJournalPage(tester, showAllJournals: true);

    await tester.tap(find.textContaining('New entry'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final entries = await DriftJournalRepository(db).listEntries();
    final added = entries.where((e) => e.id != 'harness-entry');
    expect(added, hasLength(1));
    expect(added.single.journalId, journalHarnessId);
    expect(added.single.journalId, isNot(legacyJournalId));
    await disposeJournalPage(tester);
  });

  testWidgets('the composer names the journal a new entry will land in', (
    tester,
  ) async {
    await pumpJournalPage(tester, showAllJournals: true);

    expect(find.text('New entry in $journalHarnessName'), findsOneWidget);
    await disposeJournalPage(tester);
  });

  testWidgets('the composer label stays plain outside the all-journals view', (
    tester,
  ) async {
    await pumpJournalPage(tester);

    expect(find.text('New entry'), findsOneWidget);
    await disposeJournalPage(tester);
  });
}

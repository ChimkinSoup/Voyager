// On a device's first launch after signing in, the Journal page opens before
// the pull brings in the account's default journal, and it only read the
// setting once, so it opened on the oldest journal (BUG-229). The page now
// follows a default that arrives later — unless the user has picked a view of
// their own since. The same as To-Do's BUG-228.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/journal/journal_page.dart';

import 'support/journal_page_harness.dart';

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// What the pull does: a repository write, then the providers re-read.
Future<void> _pullDefault(WidgetTester tester, AppDatabase db) async {
  final repo = DriftSettingsRepository(db);
  await repo.saveSettings(
    (await repo.getSettings()).copyWith(
      defaultJournalId: journalHarnessSecondId,
    ),
    recordLocalActivity: false,
  );
  ProviderScope.containerOf(
    tester.element(find.byType(JournalPage)),
  ).invalidate(settingsProvider);
  await _frames(tester);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a default journal that arrives after the page opened is '
      'opened', (tester) async {
    final db = await pumpJournalPage(tester, seedSecondJournal: true);
    expect(find.text('Seeded entry'), findsWidgets);
    expect(find.text('Second journal entry'), findsNothing);

    await _pullDefault(tester, db);

    expect(find.text('Second journal entry'), findsWidgets);
    expect(find.text('Seeded entry'), findsNothing);
    await disposeJournalPage(tester);
  });

  testWidgets('a journal the user picked is kept when a default arrives '
      'later', (tester) async {
    final db = await pumpJournalPage(tester, seedSecondJournal: true);
    await tester.tap(find.text(journalHarnessName).first);
    await _frames(tester);
    await tester.tap(find.text(journalHarnessName).last);
    await _frames(tester);

    await _pullDefault(tester, db);

    expect(find.text('Seeded entry'), findsWidgets);
    expect(find.text('Second journal entry'), findsNothing);
    await disposeJournalPage(tester);
  });
}

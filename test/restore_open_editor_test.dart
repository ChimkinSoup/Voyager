// A backup restore rewrites rows under pages the shell keeps mounted. The
// journal page open on an entry used to flush its pre-restore text straight
// back over the restored body the next time the window lost focus — a normal
// save, synced to every device, that quietly undid the restore.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

Finder get _bodyField => find.widgetWithText(TextField, 'Start writing...');

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Types into the seeded entry and leaves the editor focused, as the page was
/// when the restore ran.
Future<AppDatabase> _typeIntoEntry(WidgetTester tester) async {
  final db = await pumpJournalPage(tester);
  await tester.tap(_bodyField);
  await tester.pump();
  await tester.enterText(_bodyField, 'Typed before the restore');
  await _settle(tester);
  return db;
}

/// What the import does to the row: the backup's body, one version up.
Future<void> _restoreBody(AppDatabase db, String body) async {
  final repo = DriftJournalRepository(db);
  final entry = (await repo.getEntry('harness-entry'))!;
  await repo.upsertEntry(
    entry.copyWith(body: body, version: entry.version + 1),
    recordLocalActivity: false,
  );
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('without a restore, the flush saves what the editor holds', (
    tester,
  ) async {
    // The control: the same sequence with no restore in between is exactly
    // how the pre-restore text got written back.
    final db = await _typeIntoEntry(tester);
    await _restoreBody(db, 'Written underneath the editor');

    await PendingFlushRegistry.instance.flushAll();
    await _settle(tester);

    final entry = await DriftJournalRepository(db).getEntry('harness-entry');
    expect(entry!.body, 'Typed before the restore');
    await disposeJournalPage(tester);
  });

  testWidgets('after a restore, the open page saves nothing over it', (
    tester,
  ) async {
    final db = await _typeIntoEntry(tester);
    await _restoreBody(db, 'Restored text');
    restoreGeneration.value++;

    // The window losing focus, then the remount disposing the old page.
    await PendingFlushRegistry.instance.flushAll();
    await _settle(tester);
    await disposeJournalPage(tester);

    final entry = await DriftJournalRepository(db).getEntry('harness-entry');
    expect(entry!.body, 'Restored text');
  });
}

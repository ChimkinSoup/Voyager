// Guards the cost of the journal editor's ~400ms autosave.
//
// Every save used to invalidate the app-wide journal providers, and because
// they are all `keepAlive` and actively watched, each invalidation immediately
// re-read and re-mapped *every* entry row in the database — deleted rows
// included, through journalAllEntryIdsProvider, and every entry's tags again,
// through tagPoolProvider. That is what made the background animation drop
// frames while typing.
//
// The counts here are whole-table reads, not wall-clock time: timing the same
// interaction on a desktop under load swings enough between runs to hide a real
// regression, whereas a refetch count is exact and is the thing that actually
// moved.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

import 'support/journal_page_harness.dart';

/// Forwards to a real repository while tallying the reads that scan the whole
/// entries table. Those are the ones a provider invalidation triggers.
class _CountingJournalRepository implements JournalRepository {
  _CountingJournalRepository(this._delegate);

  final JournalRepository _delegate;

  var listEntriesCalls = 0;
  var getAllEntriesCalls = 0;
  var countEntriesCalls = 0;

  /// Whole-table reads since [resetCounts].
  int get tableScans => listEntriesCalls + getAllEntriesCalls + countEntriesCalls;

  void resetCounts() {
    listEntriesCalls = 0;
    getAllEntriesCalls = 0;
    countEntriesCalls = 0;
  }

  @override
  Future<List<JournalEntry>> listEntries({
    String? journalId,
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  }) {
    listEntriesCalls++;
    return _delegate.listEntries(
      journalId: journalId,
      from: from,
      to: to,
      limit: limit,
      includeDeleted: includeDeleted,
    );
  }

  @override
  Future<List<JournalEntry>> getAllEntries({bool includeDeleted = true}) {
    getAllEntriesCalls++;
    return _delegate.getAllEntries(includeDeleted: includeDeleted);
  }

  @override
  Future<Map<String, int>> countEntriesByJournal({bool includeDeleted = false}) {
    countEntriesCalls++;
    return _delegate.countEntriesByJournal(includeDeleted: includeDeleted);
  }

  // Single-row and journal-level operations are untouched by this test — an
  // autosave is expected to read and write its own row.
  @override
  Future<JournalEntry?> getEntry(String id) => _delegate.getEntry(id);

  @override
  Future<void> upsertEntry(JournalEntry entry, {bool recordLocalActivity = true}) =>
      _delegate.upsertEntry(entry, recordLocalActivity: recordLocalActivity);

  @override
  Future<void> softDeleteEntry(String id) => _delegate.softDeleteEntry(id);

  @override
  Future<void> hardDeleteEntry(String id) => _delegate.hardDeleteEntry(id);

  @override
  Future<void> purgeExpiredDeleted(DateTime now) =>
      _delegate.purgeExpiredDeleted(now);

  @override
  Future<List<Journal>> listJournals({bool includeDeleted = false}) =>
      _delegate.listJournals(includeDeleted: includeDeleted);

  @override
  Future<Journal?> getJournal(String id) => _delegate.getJournal(id);

  @override
  Future<void> upsertJournal(Journal journal, {bool recordLocalActivity = true}) =>
      _delegate.upsertJournal(journal, recordLocalActivity: recordLocalActivity);

  @override
  Future<void> softDeleteJournal(String id) => _delegate.softDeleteJournal(id);

  @override
  Future<void> softDeleteEntriesInJournal(String journalId) =>
      _delegate.softDeleteEntriesInJournal(journalId);

  @override
  Future<void> deleteAllJournals() => _delegate.deleteAllJournals();

  @override
  Future<void> deleteAllEntries() => _delegate.deleteAllEntries();

  @override
  Future<void> reassignEntriesJournal(String from, String to) =>
      _delegate.reassignEntriesJournal(from, to);
}

/// Long enough to carry the 400ms local-save debounce and let the write and
/// anything it schedules resolve.
Future<void> _settleSave(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder get _bodyField => find.widgetWithText(TextField, 'Start writing...');

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('typing does not re-read the entries table on every autosave', (
    tester,
  ) async {
    late _CountingJournalRepository repo;
    await pumpJournalPage(
      tester,
      extraOverrides: (db) => [
        journalRepositoryProvider.overrideWith((ref) {
          return repo = _CountingJournalRepository(DriftJournalRepository(db));
        }),
      ],
    );

    await tester.tap(_bodyField);
    await tester.pump();
    repo.resetCounts();

    // Three separate typing bursts, each far enough apart to fire its own
    // debounced save — this is exactly the pattern that was costing frames.
    for (final text in const ['first', 'first second', 'first second third']) {
      await tester.enterText(_bodyField, text);
      await _settleSave(tester);
    }

    expect(
      repo.tableScans,
      0,
      reason:
          'an autosave changes only the row being edited, and the list row on '
          'screen already follows it live through the title/body preview '
          'notifiers — it must not reload the entry lists. Saw '
          'listEntries=${repo.listEntriesCalls} '
          'getAllEntries=${repo.getAllEntriesCalls} '
          'countEntries=${repo.countEntriesCalls}.',
    );

    await disposeJournalPage(tester);
  });

  testWidgets('leaving the body does refresh the entry lists', (tester) async {
    late _CountingJournalRepository repo;
    await pumpJournalPage(
      tester,
      extraOverrides: (db) => [
        journalRepositoryProvider.overrideWith((ref) {
          return repo = _CountingJournalRepository(DriftJournalRepository(db));
        }),
      ],
    );

    await tester.tap(_bodyField);
    await tester.pump();
    await tester.enterText(_bodyField, 'written while focused');
    await _settleSave(tester);
    repo.resetCounts();

    // Blur is a commitment point: the page flushes and reloads the lists, so
    // everything reading them (search, analytics, the `#tag` pool) catches up.
    FocusManager.instance.primaryFocus?.unfocus();
    await _settleSave(tester);

    expect(
      repo.listEntriesCalls,
      greaterThan(0),
      reason: 'the scoped entry lists should reload once the editor is left',
    );

    await disposeJournalPage(tester);
  });
}

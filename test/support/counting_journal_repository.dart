// A [JournalRepository] that counts whole-table reads, for tests guarding
// against provider refetches.

import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Forwards to a real repository while tallying the reads that scan the whole
/// entries table. Those are the ones a provider invalidation triggers.
class CountingJournalRepository implements JournalRepository {
  CountingJournalRepository(this._delegate);

  final JournalRepository _delegate;

  var listEntriesCalls = 0;
  var getAllEntriesCalls = 0;
  var countEntriesCalls = 0;

  /// Whole-table reads since [resetCounts].
  int get tableScans =>
      listEntriesCalls + getAllEntriesCalls + countEntriesCalls;

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
  Future<Map<String, int>> countEntriesByJournal({
    bool includeDeleted = false,
  }) {
    countEntriesCalls++;
    return _delegate.countEntriesByJournal(includeDeleted: includeDeleted);
  }

  @override
  Future<Map<String, Map<String, DateTime>>> lastQuoteUseByJournal() =>
      _delegate.lastQuoteUseByJournal();

  // Single-row and journal-level operations are untouched by this test — an
  // autosave is expected to read and write its own row.
  @override
  Future<JournalEntry?> getEntry(String id) => _delegate.getEntry(id);

  @override
  Future<void> upsertEntry(
    JournalEntry entry, {
    bool recordLocalActivity = true,
  }) => _delegate.upsertEntry(entry, recordLocalActivity: recordLocalActivity);

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
  Future<void> upsertJournal(
    Journal journal, {
    bool recordLocalActivity = true,
  }) => _delegate.upsertJournal(
    journal,
    recordLocalActivity: recordLocalActivity,
  );

  @override
  Future<void> softDeleteJournal(String id, {DateTime? at}) =>
      _delegate.softDeleteJournal(id, at: at);

  @override
  Future<void> softDeleteEntriesInJournal(String journalId, {DateTime? at}) =>
      _delegate.softDeleteEntriesInJournal(journalId, at: at);

  @override
  Future<void> deleteAllJournals() => _delegate.deleteAllJournals();

  @override
  Future<void> deleteAllEntries() => _delegate.deleteAllEntries();

  @override
  Future<void> reassignEntriesJournal(String from, String to) =>
      _delegate.reassignEntriesJournal(from, to);
}

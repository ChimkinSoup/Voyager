import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';
import 'package:voyager/domain/services/search_service.dart';
import 'package:voyager/domain/services/sequence_crdt_merger.dart';

void main() {
  test('search matches all tokens independently', () {
    final service = SearchService();
    final entries = [
      JournalEntry(
        id: '1',
        journalId: 'j',
        title: 'Beach day',
        body: 'I went to the beach',
        entryDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    ];
    final results = service.searchEntries(
      entries: entries,
      query: 'beach went',
    );
    expect(results, hasLength(1));
  });

  test('periodic prompt detects missed weekly period', () {
    final service = PeriodicPromptService();
    final missed = service.missedPeriods(
      cadence: TrackerCadence.weekly,
      now: DateTime(2026, 1, 15),
      lastCompleted: DateTime(2025, 12, 20),
    );
    expect(missed, isNotEmpty);
  });

  test('analytics counts words and streak', () {
    final analytics = AnalyticsService();
    final prompt = PeriodicPromptService();
    expect(analytics.countWords('one two three'), 3);
    final streak = prompt.longestJournalStreak([
      JournalEntry(
        id: '1',
        journalId: 'j',
        title: 'a',
        body: '',
        entryDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
      JournalEntry(
        id: '2',
        journalId: 'j',
        title: 'b',
        body: '',
        entryDate: DateTime(2026, 1, 2),
        createdAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 2),
      ),
    ]);
    expect(streak, 2);
  });

  test('sequence crdt merger orders by sequence', () {
    final merger = SequenceCrdtMerger();
    final merged = merger.merge(const [], [
      SyncOperation(
        id: 'a',
        documentId: 'doc',
        sequence: 2,
        payload: 'b',
        deviceId: 'd1',
        timestamp: DateTime(2026, 1, 2),
      ),
      SyncOperation(
        id: 'b',
        documentId: 'doc',
        sequence: 1,
        payload: 'a',
        deviceId: 'd1',
        timestamp: DateTime(2026, 1, 1),
      ),
    ]);
    expect(merger.applyMergedPayload(merged), 'b');
  });

  test('soft delete expires after retention window', () {
    const policy = SoftDeletePolicy();
    final deletedAt = DateTime(2026, 1, 1);
    expect(policy.isExpired(deletedAt, DateTime(2026, 2, 5)), isTrue);
    expect(policy.isExpired(deletedAt, DateTime(2026, 1, 10)), isFalse);
  });

  test('debouncer coalesces rapid calls', () async {
    var count = 0;
    final debouncer = Debouncer(delay: const Duration(milliseconds: 50));
    debouncer.schedule(() async => count++);
    debouncer.schedule(() async => count++);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(count, 1);
    debouncer.dispose();
  });
}

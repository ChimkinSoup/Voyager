import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';
import 'package:voyager/domain/services/search_service.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
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

  test('legacy snapshot operations do not synthesize duplicate char ops', () {
    final merger = CharacterSequenceCrdtMerger();
    final ops = [
      SyncOperation(
        id: 'op-1',
        documentId: 'entry-1',
        sequence: 1,
        payload: jsonEncode({'body': 'abc', 'title': 'One'}),
        deviceId: 'd1',
        timestamp: DateTime(2026, 1, 1),
      ),
      SyncOperation(
        id: 'op-2',
        documentId: 'entry-1',
        sequence: 2,
        payload: jsonEncode({'body': 'abcd', 'title': 'One'}),
        deviceId: 'd1',
        timestamp: DateTime(2026, 1, 2),
      ),
    ];
    expect(merger.mergeOperations(const [], ops), isEmpty);
    final resolved = jsonDecode(merger.applyMergedPayload(ops)) as Map;
    expect(resolved['body'], 'abcd');
  });

  test('character sequence crdt merges concurrent inserts by position', () {
    final merger = CharacterSequenceCrdtMerger();
    final ops = [
      CharacterOperation(
        id: 'a',
        clientId: 'c1',
        logicalClock: 1,
        position: 'a0',
        character: 'H',
      ),
      CharacterOperation(
        id: 'b',
        clientId: 'c2',
        logicalClock: 1,
        position: 'a1',
        character: 'i',
      ),
    ];
    expect(merger.applyMergedText(ops), 'Hi');
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

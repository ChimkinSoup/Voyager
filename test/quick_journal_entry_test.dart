// The journal hotkey's Quick Journal Entry: one per local day, reused until it
// is deleted, filed under the last-touched journal.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/hotkeys/quick_journal_entry.dart';

import 'fakes/fake_weather_api_client.dart';

class _MemoryPointerStore implements QuickJournalPointerStore {
  ({String day, String entryId})? pointer;

  @override
  Future<({String day, String entryId})?> load() async => pointer;

  @override
  Future<void> save(String day, String entryId) async =>
      pointer = (day: day, entryId: entryId);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  late AppDatabase db;
  late _MemoryPointerStore pointers;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.inMemory();
    pointers = _MemoryPointerStore();
    final now = DateTime.now().toUtc();
    final repo = DriftJournalRepository(db);
    for (final id in ['journal-a', 'journal-b']) {
      await repo.upsertJournal(
        Journal(id: id, name: id, createdAt: now, updatedAt: now),
      );
    }
    final settingsRepo = DriftSettingsRepository(db);
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        lastViewedJournalId: 'journal-b',
      ),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        quickJournalPointerStoreProvider.overrideWithValue(pointers),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('creates today\'s entry once, in the last-touched journal', () async {
    final first = await resolveQuickJournalEntry(container);
    final second = await resolveQuickJournalEntry(container);

    expect(second.id, first.id);
    expect(first.journalId, 'journal-b');
    expect(first.body, isEmpty);
    final stored = await DriftJournalRepository(db).getEntry(first.id);
    expect(stored, isNotNull);
  });

  test('gets a quote even with a cold quote bank', () async {
    final entry = await resolveQuickJournalEntry(container);

    expect(entry.customQuote, isNotNull);
    expect(entry.quoteId, isNotNull);
    final stored = await DriftJournalRepository(db).getEntry(entry.id);
    expect(stored!.customQuote, entry.customQuote);
  });

  test('concurrent opens share one entry', () async {
    final results = await Future.wait([
      resolveQuickJournalEntry(container),
      resolveQuickJournalEntry(container),
    ]);
    expect(results[0].id, results[1].id);
  });

  test('a deleted entry is replaced by a fresh one the same day', () async {
    final first = await resolveQuickJournalEntry(container);
    await DriftJournalRepository(db).softDeleteEntry(first.id);

    final next = await resolveQuickJournalEntry(container);
    expect(next.id, isNot(first.id));
  });

  test('yesterday\'s entry is not reused', () async {
    final yesterday = await resolveQuickJournalEntry(container);
    pointers.pointer = (day: '2000-01-01', entryId: yesterday.id);

    final today = await resolveQuickJournalEntry(container);
    expect(today.id, isNot(yesterday.id));
  });
}

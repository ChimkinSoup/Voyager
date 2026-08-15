// The dream-journal counterpart to journal_autosave_provider_refetch_test.dart.
//
// The dream editor's ~400ms autosave used to invalidate allDreamEntriesProvider
// on every save. That provider re-reads and re-maps every dream row, and it
// fans out further — tagPoolProvider re-ranks every dream's tags off it, and so
// does the "dream logged" tracker — none of which an edit to one dream's text
// can change.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';

/// Forwards to a real repository while tallying the reads that scan the whole
/// dreams table — the ones a provider invalidation triggers.
class _CountingDreamRepository implements DreamRepository {
  _CountingDreamRepository(this._delegate);

  final DreamRepository _delegate;

  var listEntriesCalls = 0;
  var getAllEntriesCalls = 0;

  int get tableScans => listEntriesCalls + getAllEntriesCalls;

  void resetCounts() {
    listEntriesCalls = 0;
    getAllEntriesCalls = 0;
  }

  @override
  Future<List<DreamEntry>> listEntries({
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  }) {
    listEntriesCalls++;
    return _delegate.listEntries(
      from: from,
      to: to,
      limit: limit,
      includeDeleted: includeDeleted,
    );
  }

  @override
  Future<List<DreamEntry>> getAllEntries({bool includeDeleted = true}) {
    getAllEntriesCalls++;
    return _delegate.getAllEntries(includeDeleted: includeDeleted);
  }

  @override
  Future<DreamEntry?> getEntry(String id) => _delegate.getEntry(id);

  @override
  Future<void> upsertEntry(DreamEntry entry, {bool recordLocalActivity = true}) =>
      _delegate.upsertEntry(entry, recordLocalActivity: recordLocalActivity);

  @override
  Future<void> softDeleteEntry(String id) => _delegate.softDeleteEntry(id);

  @override
  Future<void> hardDeleteEntry(String id) => _delegate.hardDeleteEntry(id);

  @override
  Future<void> purgeExpiredDeleted(DateTime now) =>
      _delegate.purgeExpiredDeleted(now);
}

Future<_CountingDreamRepository> _pumpDreamPage(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  final now = DateTime.now().toUtc();
  await DriftDreamRepository(db).upsertEntry(
    DreamEntry(
      id: 'harness-dream',
      title: 'Seeded dream',
      body: '',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    ),
  );

  final repo = _CountingDreamRepository(DriftDreamRepository(db));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      dreamRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
    ),
  );
  // Not pumpAndSettle: the page keeps animations alive, so settling never
  // completes.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return repo;
}

/// Long enough to carry the 400ms local-save debounce and let the write and
/// anything it schedules resolve.
Future<void> _settleSave(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder get _bodyField => find.widgetWithText(
  TextField,
  'Describe your dream... use #tags to mark themes',
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('typing does not re-read the dreams table on every autosave', (
    tester,
  ) async {
    final repo = await _pumpDreamPage(tester);

    await tester.tap(_bodyField);
    await tester.pump();
    repo.resetCounts();

    for (final text in const ['flying', 'flying over', 'flying over water']) {
      await tester.enterText(_bodyField, text);
      await _settleSave(tester);
    }

    expect(
      repo.tableScans,
      0,
      reason:
          'an autosave changes only the dream being edited, and its list row '
          'already follows the save through the title/body preview notifiers. '
          'Saw listEntries=${repo.listEntriesCalls} '
          'getAllEntries=${repo.getAllEntriesCalls}.',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _settleSave(tester);
  });

  testWidgets('leaving the body does refresh the dream list', (tester) async {
    final repo = await _pumpDreamPage(tester);

    await tester.tap(_bodyField);
    await tester.pump();
    await tester.enterText(_bodyField, 'written while focused');
    await _settleSave(tester);
    repo.resetCounts();

    // Blur is a commitment point. The autosave has already written this exact
    // text, so the flush finds nothing to save — the reload still has to
    // happen, or everything reading the list stays stale for good.
    FocusManager.instance.primaryFocus?.unfocus();
    await _settleSave(tester);

    expect(
      repo.getAllEntriesCalls,
      greaterThan(0),
      reason: 'the dream list should reload once the editor is left',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _settleSave(tester);
  });
}

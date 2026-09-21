// The undo toast on the Dream Journal's delete.
//
// Deleting the open dream clears the editor and lets [build]'s auto-select
// move on to whatever is left, so a restore that only writes the row back
// leaves the page showing a different dream than the one the user just asked
// to have back. Both halves are asserted here.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';

/// Seeds two dreams — deleting one then leaves something for the auto-select
/// to land on, which is the case the undo has to take back.
Future<AppDatabase> _pumpDreamPage(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  final now = DateTime.now().toUtc();
  final repo = DriftDreamRepository(db);
  for (var i = 0; i < 2; i++) {
    await repo.upsertEntry(
      DreamEntry(
        id: 'harness-dream-$i',
        title: 'Dream $i',
        body: '',
        entryDate: now.subtract(Duration(days: i)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
    ),
  );
  await _settle(tester);
  return db;
}

/// The page keeps animations alive, so `pumpAndSettle` never returns.
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// What the editor's title field is showing, which is the page's answer to
/// "which dream is open".
///
/// Read off the widget rather than found by text: the label is painted by
/// [LabeledTextField]'s own border painter, so there is no `Text('Title')` to
/// match on.
String _openTitle(WidgetTester tester) {
  final field = tester
      .widgetList<LabeledTextField>(find.byType(LabeledTextField))
      .firstWhere((field) => field.label == 'Title');
  return field.controller.text;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('undoing a delete brings the dream back and reopens it', (
    tester,
  ) async {
    final db = await _pumpDreamPage(tester);
    final repo = DriftDreamRepository(db);

    // Dream 0 is the newest, so it is the one the page opens on.
    expect(_openTitle(tester), 'Dream 0');

    await tester.tap(find.byTooltip('Delete dream'));
    await _settle(tester);
    expect(find.text('Delete dream?'), findsOneWidget);
    await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
    await _settle(tester);

    expect(_openTitle(tester), 'Dream 1');
    expect(find.text('Deleted "Dream 0"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await _settle(tester);

    final restored = (await repo.listEntries()).where(
      (e) => e.title == 'Dream 0',
    );
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    expect(
      restored.single.version,
      greaterThan(1),
      reason: 'the restore has to outrank the tombstone on the next sync',
    );
    expect(
      _openTitle(tester),
      'Dream 0',
      reason: 'undo opens the dream it brought back, not the replacement',
    );
  });
}

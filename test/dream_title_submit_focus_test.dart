// Enter in the dream title hands focus to the body, the same as Tab already
// did and the same as the journal page's title does.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';

Future<AppDatabase> _pumpDreamPage(WidgetTester tester) async {
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
  // Not pumpAndSettle: the page keeps animations alive, so settling never
  // completes.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return db;
}

Future<void> _settleSave(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder get _bodyField => find.widgetWithText(
  TextField,
  'Describe your dream... use #tags to mark themes',
);

/// The title box, found by the seeded dream's title — the label itself is
/// painted into the field's border, not a [Text] widget.
Finder get _titleField => find.widgetWithText(TextField, 'Seeded dream');

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('Enter in the title moves focus to the body', (tester) async {
    final db = await _pumpDreamPage(tester);

    await tester.tap(_titleField);
    await tester.pump();
    await tester.enterText(_titleField, 'Renamed dream');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.next);
    await _settleSave(tester);

    expect(
      tester.widget<TextField>(_bodyField).focusNode?.hasFocus,
      isTrue,
      reason: 'Enter should hand focus to the body, the same as Tab does',
    );
    // The blur Enter causes is the commitment point that saves the title.
    expect(
      (await DriftDreamRepository(db).getEntry('harness-dream'))?.title,
      'Renamed dream',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _settleSave(tester);
  });
}

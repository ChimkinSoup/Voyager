// BUG-246: a dream deleted on another device while it was open here stayed in
// the editor, and since saves into a deleted row are dropped, everything typed
// into it afterwards was lost without a word. The page now leaves it, as it
// does after its own delete.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
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

const _noteHint = 'Jot a quick note to jog your memory later...';

Future<void> _pump(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Waits on [future] while frames run, so database work started inside the
/// test's fake clock can finish.
Future<T> _settle<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  future.then((result) {
    value = result;
    done = true;
  });
  for (var i = 0; i < 100 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done, isTrue);
  return value;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the editor leaves a dream deleted on another device', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftDreamRepository(db);
    final now = DateTime.now().toUtc();
    await repo.upsertEntry(
      DreamEntry(
        id: 'dream-old',
        title: 'Other dream',
        body: 'Other body.',
        entryDate: now.subtract(const Duration(days: 1)),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertEntry(
      DreamEntry(
        id: 'dream-new',
        title: 'Doomed dream',
        body: 'Doomed body.',
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
    await _pump(tester, frames: 12);
    expect(find.widgetWithText(TextField, 'Doomed dream'), findsOneWidget);

    // Typing in the note when the deletion arrives.
    await tester.tap(
      find.byIcon(Icons.sticky_note_2_outlined),
      kind: PointerDeviceKind.mouse,
    );
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, _noteHint), 'typing');
    await _pump(tester, frames: 12);

    final stored = (await _settle(tester, repo.getEntry('dream-new')))!;
    await _settle(
      tester,
      repo.upsertEntry(
        stored.copyWith(deletedAt: now.add(const Duration(seconds: 1))),
        recordLocalActivity: false,
      ),
    );
    container.invalidate(allDreamEntriesProvider);
    await _pump(tester, frames: 20);

    expect(find.widgetWithText(TextField, 'Doomed dream'), findsNothing);
    expect(find.widgetWithText(TextField, 'Other dream'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNot(isA<EditableText>()),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

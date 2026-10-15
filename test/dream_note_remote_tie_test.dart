// BUG-239: a note the sync took from the other device, at the very stamps of
// this device's own save, reached the row while the open note field still
// showed this device's text. A flush wrote that stale text back over it, and
// the field kept showing it after the note closed.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
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

  testWidgets('a remote note at the same stamps is neither overwritten nor '
      'hidden by the open note', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftDreamRepository(db);
    final now = DateTime.now().toUtc();
    await repo.upsertEntry(
      DreamEntry(
        id: 'dream-0',
        title: 'A dream',
        body: 'Dream body stays.',
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

    await tester.tap(
      find.byIcon(Icons.sticky_note_2_outlined),
      kind: PointerDeviceKind.mouse,
    );
    await _pump(tester);
    await tester.enterText(
      find.widgetWithText(TextField, _noteHint),
      'note by B',
    );
    await _pump(tester, frames: 12);
    final saved = (await _settle(tester, repo.getEntry('dream-0')))!;
    expect(saved.notes, 'note by B');

    // The sync's tie-break hands the row the other device's note, at the
    // stamps this device's save left.
    await _settle(
      tester,
      repo.upsertEntry(
        DreamEntry(
          id: saved.id,
          title: saved.title,
          body: saved.body,
          notes: 'note by A',
          entryDate: saved.entryDate,
          createdAt: saved.createdAt,
          updatedAt: saved.updatedAt,
          version: saved.version,
        ),
        recordLocalActivity: false,
      ),
    );
    container.invalidate(allDreamEntriesProvider);
    await _pump(tester);

    // Still in the note: a flush must not write its stale text back.
    await _settle(tester, PendingFlushRegistry.instance.flushAll());
    await _pump(tester);
    expect(
      (await _settle(tester, repo.getEntry('dream-0')))!.notes,
      'note by A',
    );

    await tester.tap(find.byTooltip('Close'), kind: PointerDeviceKind.mouse);
    await _pump(tester, frames: 12);
    await tester.tap(
      find.byIcon(Icons.sticky_note_2_outlined),
      kind: PointerDeviceKind.mouse,
    );
    await _pump(tester);
    expect(find.widgetWithText(TextField, 'note by A'), findsOneWidget);
    expect(
      (await _settle(tester, repo.getEntry('dream-0')))!.notes,
      'note by A',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

// The Dream Journal's twin of journal_entry_switch_survives_stalled_upload.
//
// Typing into a dream leaves a debounced Firestore upload pending on it.
// Switching away used to run that upload as part of the flush and wait for the
// server to acknowledge it — a wait that, with offline persistence, never ends
// while Firestore is unreachable. Every write on this page goes through one
// serial queue (`_queueWrite`), so a single hung upload parked the queue and
// the page could not change dreams again at all.

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';

/// Accepts the operation-log write and then never answers, standing in for a
/// Firestore write made while the device cannot reach the server.
class _StalledSyncRepository extends InMemorySyncRepository {
  final _held = Completer<void>();

  void release() {
    if (!_held.isCompleted) _held.complete();
  }

  @override
  Future<void> appendOperationGroup(List<SyncOperation> operations) {
    return _held.future;
  }
}

/// The page keeps animations alive, so `pumpAndSettle` never returns.
Future<void> _settle(
  WidgetTester tester, {
  required int frames,
  Duration step = const Duration(milliseconds: 60),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// What the editor's title field is showing, which is the page's answer to
/// "which dream is open". Read off the widget rather than found by text: the
/// label is painted by [LabeledTextField]'s own border painter.
String _openTitle(WidgetTester tester) {
  final field = tester
      .widgetList<LabeledTextField>(find.byType(LabeledTextField))
      .firstWhere((field) => field.label == 'Title');
  return field.controller.text;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a dream can still be opened after an edit stalls its upload', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final sync = _StalledSyncRepository();
    addTearDown(sync.release);

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
        syncRepositoryProvider.overrideWithValue(sync),
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
    await _settle(tester, frames: 12);
    expect(_openTitle(tester), 'Dream 0');

    // Past the 400ms local-save debounce, so the edit is on disk and its
    // upload is scheduled, but inside the upload's own debounce — so the
    // pending upload is still on the queue for the switch's flush to run.
    await tester.enterText(
      find.widgetWithText(LabeledTextField, 'Dream 0'),
      'Dream 0 edited',
    );
    await _settle(tester, frames: 10, step: const Duration(milliseconds: 60));

    await tester.tap(find.text('Dream 1'));
    // ~300ms of frames: enough for a flush that only touches SQLite, and far
    // short of a flush that waits on the stalled upload — which never returns.
    await _settle(tester, frames: 12, step: const Duration(milliseconds: 25));

    expect(_openTitle(tester), 'Dream 1');

    sync.release();
    await _settle(tester, frames: 8);
  });
}

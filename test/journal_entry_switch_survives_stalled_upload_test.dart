// Creating an entry leaves a Firestore upload pending on it. Switching away
// used to run that upload as part of the flush, and with offline persistence
// the Firestore write never completes while the server is unreachable — which
// parked every later entry switch behind `_flushInProgress` for good: taps
// fired, the flush never returned, and the selection never moved.
//
// Bounding that wait was not enough: the switch then simply took the deadline,
// so creating an entry left the list unclickable for as long as the bound. The
// flush waits on nothing remote now, so the assertion below is deliberately
// made inside a window far shorter than any such deadline.

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';

import 'support/journal_page_harness.dart';

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

Future<void> settle(
  WidgetTester tester, {
  required int frames,
  Duration step = const Duration(milliseconds: 60),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('an entry can still be opened after a new entry stalls its '
      'upload', (tester) async {
    final sync = _StalledSyncRepository();
    addTearDown(sync.release);

    await pumpJournalPage(
      tester,
      extraOverrides: (_) => [syncRepositoryProvider.overrideWithValue(sync)],
    );

    // Switching away inside the 1s upload debounce, the way a user who creates
    // an entry and immediately clicks another one does. The new entry's upload
    // is still on the pending queue, so the switch's flush is what runs it.
    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 8, step: const Duration(milliseconds: 25));

    // The new, untitled entry is what the page switched to.
    expect(find.widgetWithText(TextField, 'Seeded entry'), findsNothing);

    await tester.tap(find.text('Seeded entry'));
    // ~300ms of frames: enough for a flush that only touches SQLite, and far
    // short of the seconds a flush that waits on the stalled upload takes.
    await settle(tester, frames: 12, step: const Duration(milliseconds: 25));

    expect(find.widgetWithText(TextField, 'Seeded entry'), findsOneWidget);

    sync.release();
    await disposeJournalPage(tester);
  });
}

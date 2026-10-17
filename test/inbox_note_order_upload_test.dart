// How a dragged inbox note order reaches the server: a moment after the last
// drop, through the same checked settings upload as every other setting.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';

import 'fakes/fake_weather_api_client.dart';

class _CountingSync extends InMemorySyncRepository {
  final uploads = <AppSettings>[];

  @override
  Future<void> uploadSettings(AppSettings settings) {
    uploads.add(settings);
    return super.uploadSettings(settings);
  }
}

Future<(ProviderContainer, _CountingSync)> _setUp(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final sync = _CountingSync();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(sync),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(() => container.read(settingsProvider.future));
  // Registers the service for repository writes.
  container.read(remoteSyncServiceProvider);
  return (container, sync);
}

Future<void> _save(
  WidgetTester tester,
  ProviderContainer container,
  List<String> ids, {
  required bool secure,
}) async {
  await tester.runAsync(
    () => container
        .read(settingsProvider.notifier)
        .saveInboxNoteOrder(ids, secure: secure),
  );
  await tester.pump();
}

/// Past the upload delay. In real time: the saves run in [runAsync], so the
/// upload's timer does too.
Future<void> _waitForUpload(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 1500)),
  );
  await tester.pump();
}

void main() {
  testWidgets('drops in a burst upload once, with the last order', (
    tester,
  ) async {
    final (container, sync) = await _setUp(tester);

    await _save(tester, container, ['a', 'b', 'c'], secure: false);
    await _save(tester, container, ['b', 'a', 'c'], secure: false);
    await _save(tester, container, ['y', 'x'], secure: true);
    expect(sync.uploads, isEmpty);

    await _waitForUpload(tester);

    expect(sync.uploads, hasLength(1));
    expect(sync.uploads.single.inboxPinnedNoteOrder, ['b', 'a', 'c']);
    expect(sync.uploads.single.inboxSecureNoteOrder, ['y', 'x']);
    // Through the checked patch, which carries what changed.
    final remote = (await sync.getRemoteSettings())!;
    expect(remote['inboxPinnedNoteOrder'], ['b', 'a', 'c']);
    expect(remote['inboxSecureNoteOrder'], ['y', 'x']);
  });

  testWidgets('the uploaded order reaches another device', (tester) async {
    final (container, sync) = await _setUp(tester);
    await _save(tester, container, ['b', 'a'], secure: false);
    await _waitForUpload(tester);

    final remote = (await sync.getRemoteSettings())!;
    expect(
      mergeSettingsFromRemote(remote, const AppSettings()).inboxPinnedNoteOrder,
      ['b', 'a'],
    );
  });

  testWidgets('another settings change still uploads at once', (tester) async {
    final (container, sync) = await _setUp(tester);
    final settings = container.read(settingsProvider).requireValue;

    await tester.runAsync(
      () => container
          .read(settingsProvider.notifier)
          .saveSettings(settings.copyWith(showQuotes: !settings.showQuotes)),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(sync.uploads, hasLength(1));
  });

  testWidgets('a settings change made during the wait sends the order with it', (
    tester,
  ) async {
    final (container, sync) = await _setUp(tester);

    await _save(tester, container, ['b', 'a'], secure: false);
    final settings = container.read(settingsProvider).requireValue;
    await tester.runAsync(
      () => container
          .read(settingsProvider.notifier)
          .saveSettings(settings.copyWith(showQuotes: !settings.showQuotes)),
    );
    await _waitForUpload(tester);

    expect(sync.uploads, hasLength(1));
    expect(sync.uploads.single.inboxPinnedNoteOrder, ['b', 'a']);
  });

  // Last: the outbox worker is a singleton this leaves initialized.
  testWidgets('the order is owed on the outbox until it uploads', (
    tester,
  ) async {
    final (container, sync) = await _setUp(tester);
    final db = container.read(databaseProvider);
    OutboxSyncWorker.initialize(db, FakeFirebaseFirestore(), () => null);
    Future<List<String>> owed() => tester.runAsync(() async {
      final rows = await db.select(db.pendingUploadsTable).get();
      return [for (final row in rows) row.collectionName];
    }).then((rows) => rows!);

    await _save(tester, container, ['b', 'a'], secure: false);
    // Before the upload: a process exiting now still leaves it owed.
    expect(sync.uploads, isEmpty);
    expect(await owed(), [FirestoreCollections.settings]);

    await _waitForUpload(tester);

    expect(sync.uploads, hasLength(1));
    expect(await owed(), isEmpty);
  });
}

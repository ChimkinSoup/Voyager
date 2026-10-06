// On a new device the calendar page creates the default calendar before the
// startup pull has run. Uploading that fresh v0 copy replaced a default renamed
// on another device, everywhere (BUG-045).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the default calendar made on an empty device stays local until the pull',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      final announced = <String>[];
      final syncedWrites = SyncedWriteNotifier()
        ..onWrite = (collection, _) => announced.add(collection);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          syncedWriteNotifierProvider.overrideWithValue(syncedWrites),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: CalendarPage())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final repo = DriftCalendarRepository(db);
      final placeholder = (await repo.getCalendar(legacyCalendarId))!;
      expect(placeholder.name, 'Calendar');
      expect(announced, isNot(contains(FirestoreCollections.calendars)));

      // The pull then brings down the default renamed on another device.
      final now = utcNow();
      final renamed = Calendar(
        id: legacyCalendarId,
        name: 'Renamed elsewhere',
        colorValue: 0xFFFF66AA,
        createdAt: now.subtract(const Duration(days: 30)),
        updatedAt: now.subtract(const Duration(days: 1)),
        version: 1,
      );
      final merged = mergeCalendarFromRemote(
        calendarToFirestore(renamed),
        legacyCalendarId,
        local: placeholder,
      );
      expect(merged.name, 'Renamed elsewhere');
      expect(merged.colorValue, 0xFFFF66AA);
    },
  );
}

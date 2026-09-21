// A bucket-list line is a one-line row, so removing one has never asked for
// confirmation and still does not (SOFT_DELETE_TOAST.md §5.3 forbids adding
// one). The undo toast is what makes that safe, so both halves are pinned:
// no dialog on the way out, and a way back for eight seconds.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/features/life_tracker/bucket_list_popup.dart';

import 'fakes/fake_weather_api_client.dart';

Future<DriftBucketListRepository> pumpBucketList(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftBucketListRepository(db);
  final now = utcNow();
  for (var i = 0; i < 2; i++) {
    await repo.upsertItem(
      BucketListItem(
        id: 'item-$i',
        title: 'Climb $i',
        sortOrder: i,
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
  await container.read(bucketListItemsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: BucketListPopup(accentColor: Colors.green)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('removing an item toasts without asking first', (tester) async {
    final repo = await pumpBucketList(tester);

    await tester.tap(
      find
          .descendant(
            of: find
                .ancestor(of: find.text('Climb 0'), matching: find.byType(Row))
                .last,
            matching: find.byIcon(Icons.close),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: 'a one-line row must not grow a confirm dialog',
    );
    expect(find.text('Deleted "Climb 0"'), findsOneWidget);
    expect(
      (await repo.listItems()).map((i) => i.title),
      isNot(contains('Climb 0')),
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restored = (await repo.listItems()).where(
      (i) => i.title == 'Climb 0',
    );
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    expect(
      restored.single.version,
      greaterThan(1),
      reason: 'the restore has to outrank the tombstone on the next sync',
    );
    expect(find.text('Climb 0'), findsOneWidget);
  });
}

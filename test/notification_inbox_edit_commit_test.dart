// Saving a pinned reminder is asynchronous: the row leaves the editor at once,
// but the rewritten note only arrives from the database some frames later.
// Until it does, the row's own PinnedNote still holds the *pre-edit* text —
// so a reminder that grew from two lines to four used to collapse back to two
// for the length of the write before snapping open again.
//
// This pins the frame that flash lived in: the first one after the commit.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

const _note = 'Water the plants';
const _grown = 'Water the plants\nand the basil\nand the mint\nand the thyme';

Future<void> _pumpInbox(WidgetTester tester) async {
  tester.view.physicalSize = const Size(600, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      // The popover's sections reach for the sync service, which builds the
      // real weather client and with it Firebase.
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  final now = utcNow();
  await container
      .read(notificationRepositoryProvider)
      .upsertPinnedNote(
        PinnedNote(id: newId(), text: _note, createdAt: now, updatedAt: now),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: const Scaffold(body: NotificationInboxPopover()),
      ),
    ),
  );
  // Not pumpAndSettle: the popover keeps hover/opacity animations ticking
  // while the providers resolve.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  testWidgets('a reminder saved with more lines never shows its old shape', (
    tester,
  ) async {
    await _pumpInbox(tester);

    await tester.tap(find.text(_note));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.enterText(find.byType(TextField).last, _grown);
    await tester.pump();

    // Enter with no shift is what commits the note.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      find.text(_grown),
      findsOneWidget,
      reason: 'the frame straight after the commit is the one that used to '
          'fall back to the stored — pre-edit — text',
    );
    expect(find.text(_note), findsNothing);

    // And it stays that way once the write has actually landed.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text(_grown), findsOneWidget);
  });
}

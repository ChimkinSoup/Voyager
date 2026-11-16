// The Inbox's quick-reminder field shares its draft with the quick-note
// floater, both ways: a note the floater adds leaves the field too.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  testWidgets('the field follows the draft the floater changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(380, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await container.read(pinnedNotesProvider.future);
    container.read(noteCaptureDraftProvider.notifier).state = 'fix sidebar';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 380, child: NotificationInboxPopover()),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('fix sidebar'), findsOneWidget);

    // The floater added it, clearing the draft.
    container.read(noteCaptureDraftProvider.notifier).state = '';
    await tester.pump();
    expect(find.text('fix sidebar'), findsNothing);
    expect(container.read(noteCaptureDraftProvider), '');
  });
}

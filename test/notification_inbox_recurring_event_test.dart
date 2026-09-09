// A repeating event used to be judged on the anchor row's own start/end, so
// the moment its first occurrence passed the whole series vanished from the
// bell — a daily standup added last month could never reach the inbox again.
// This drives the real popover off the real providers to pin that end to end.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

const Size _kWindow = Size(380, 640);

Future<void> _pumpInbox(
  WidgetTester tester,
  ProviderContainer container,
) async {
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
  // Not pumpAndSettle: the popover keeps hover/opacity animations ticking
  // while the providers resolve.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  testWidgets('a repeating event still due today reaches the inbox', (
    tester,
  ) async {
    tester.view.physicalSize = _kWindow;
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

    // Anchored a month back at this same wall-clock time, so today's
    // occurrence is starting about now while the stored row's own start and
    // end are long past.
    final now = DateTime.now();
    final anchor = DateTime(
      now.year,
      now.month,
      now.day - 30,
      now.hour,
      now.minute,
    );
    final stamp = utcNow();
    await container
        .read(calendarRepositoryProvider)
        .upsertEvent(
          CalendarEvent(
            id: newId(),
            createdAt: stamp,
            updatedAt: stamp,
            calendarId: 'cal',
            title: 'Daily standup',
            start: anchor,
            end: anchor.add(const Duration(hours: 1)),
            isFullDay: false,
            recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
          ),
        );

    await _pumpInbox(tester, container);

    expect(find.text('Daily standup'), findsOneWidget);
    // The row is the *occurrence*, so it is dated today rather than a month
    // ago — the subtitle is "Today · <time>".
    expect(find.textContaining('Today · '), findsOneWidget);
  });
}

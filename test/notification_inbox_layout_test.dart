// The inbox popover is one scroll region. No section owns a viewport of its
// own, so a drag started on a reminder moves the header, the feed and the
// footers with it — the panel scrolls as a single sheet rather than trapping
// the gesture in whichever box it landed on.
//
// The footers are the other half of the redesign: the daily-stats logger used
// to be mounted and visible every time the bell was clicked, four unrelated
// jobs deep in one column. It is a drawer now, and it does not exist until it
// is opened.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

/// Short enough that the popover's 75%-of-viewport cap really does bite with
/// this many feed rows in it.
const Size _kWindow = Size(380, 460);

/// A task due today is `important`, so it lands in the visible feed.
TodoTask _dueToday(int i) {
  final now = utcNow();
  return TodoTask(
    id: newId(),
    createdAt: now,
    updatedAt: now,
    listId: 'list',
    title: 'Task $i',
    dueDate: DateTime.now(),
    sortOrder: i,
  );
}

Future<ProviderContainer> _pumpInbox(
  WidgetTester tester, {
  int tasks = 0,
  bool withTracker = false,
}) async {
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

  final now = utcNow();
  await container
      .read(notificationRepositoryProvider)
      .upsertPinnedNote(
        PinnedNote(
          id: newId(),
          text: 'Water the plants',
          createdAt: now,
          updatedAt: now,
        ),
      );
  if (tasks > 0) {
    // The feed walks the lists, so the tasks need one to hang off.
    await container
        .read(todoRepositoryProvider)
        .upsertList(
          TodoListModel(
            id: 'list',
            createdAt: now,
            updatedAt: now,
            name: 'Inbox',
          ),
        );
    for (var i = 0; i < tasks; i++) {
      await container.read(todoRepositoryProvider).upsertTask(_dueToday(i));
    }
  }
  if (withTracker) {
    await container
        .read(trackerRepositoryProvider)
        .upsertTracker(
          StatisticTracker(
            id: newId(),
            name: 'Energy',
            type: TrackerType.integer,
            cadence: TrackerCadence.daily,
            integerCap: 10,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

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
  return container;
}

void main() {
  testWidgets('the whole panel scrolls as one, dragged from the reminders', (
    tester,
  ) async {
    await _pumpInbox(tester, tasks: 12);
    expect(find.text('Task 0'), findsOneWidget);

    final headerBefore = tester.getTopLeft(find.text('Inbox')).dy;
    final labelBefore = tester.getTopLeft(find.text('Reminders')).dy;
    final rowBefore = tester.getTopLeft(find.text('Task 0')).dy;

    // Started on the reminders label — the section that used to hold the
    // gesture inside its own viewport.
    await tester.drag(find.text('Reminders'), const Offset(0, -80));
    await tester.pump();

    const delta = -80.0;
    expect(tester.getTopLeft(find.text('Inbox')).dy, headerBefore + delta);
    expect(tester.getTopLeft(find.text('Reminders')).dy, labelBefore + delta);
    expect(
      tester.getTopLeft(find.text('Task 0')).dy,
      rowBefore + delta,
      reason: 'header, reminders and feed move together',
    );
  });

  testWidgets('log stats is a closed drawer until it is opened', (
    tester,
  ) async {
    await _pumpInbox(tester, withTracker: true);

    expect(find.text('Log stats'), findsOneWidget);
    expect(
      find.byType(TrackerEntryRow),
      findsNothing,
      reason: 'the logger is not built until asked for',
    );

    // Below the fold in this short window, under the Scheduled section.
    await tester.ensureVisible(find.text('Log stats'));
    await tester.pumpAndSettle();
    // The trigger's ink sits behind the label so the whole row highlights,
    // so tap that rather than the (pointer-ignoring) label itself.
    await tester.tap(
      find
          .ancestor(of: find.text('Log stats'), matching: find.byType(Stack))
          .first,
    );
    // The drawer opens over 220ms, and the row it reveals only paints once
    // its own values provider has resolved.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    expect(find.byType(TrackerEntryRow), findsOneWidget);
    expect(find.text('Energy'), findsOneWidget);

    // Opening the drawer puts the date capsule on the right half of the
    // trigger. The row's ink has to stay full width behind it, or only the
    // label half highlights on hover.
    final trigger = find
        .ancestor(of: find.text('Log stats'), matching: find.byType(Stack))
        .first;
    final ink = find
        .descendant(of: trigger, matching: find.byType(InkWell))
        .first;
    expect(tester.getRect(ink), tester.getRect(trigger));
    expect(
      tester.getRect(ink).right,
      greaterThanOrEqualTo(tester.getRect(find.text('Today')).right),
      reason: 'the highlight reaches past the date capsule',
    );
  });
}

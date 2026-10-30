// The inbox's Log stats section: it remembers being open across popovers and
// restarts, and opening it scrolls it into view.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

class _Inbox {
  _Inbox(this.container, this.open);

  final ProviderContainer container;
  final ValueNotifier<bool> open;

  Future<bool> persisted() async =>
      (await container.read(settingsRepositoryProvider).getSettings())
          .inboxLogStatsExpanded;
}

Future<_Inbox> _pumpInbox(
  WidgetTester tester, {
  int tasks = 0,
  int trackers = 0,
  AppDatabase? db,
}) async {
  tester.view.physicalSize = const Size(380, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  if (db == null) {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
  }
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  final now = utcNow();
  if (tasks > 0) {
    final todos = container.read(todoRepositoryProvider);
    await todos.upsertList(
      TodoListModel(id: 'list', createdAt: now, updatedAt: now, name: 'L'),
    );
    for (var i = 0; i < tasks; i++) {
      await todos.upsertTask(
        TodoTask(
          id: newId(),
          createdAt: now,
          updatedAt: now,
          listId: 'list',
          title: 'Task $i',
          dueDate: DateTime.now(),
          sortOrder: i,
        ),
      );
    }
  }
  for (var i = 0; i < trackers; i++) {
    await container
        .read(trackerRepositoryProvider)
        .upsertTracker(
          StatisticTracker(
            id: 'tracker-$i',
            createdAt: now,
            updatedAt: now,
            name: 'Tracker $i',
            type: TrackerType.boolean,
            cadence: TrackerCadence.daily,
            sortOrder: i,
          ),
        );
  }
  // The section reads its saved state synchronously when it mounts, as it
  // does in the app, where settings are loaded long before the bell is.
  await container.read(settingsProvider.future);
  await container.read(trackersProvider.future);

  final inbox = _Inbox(container, ValueNotifier(true));
  addTearDown(inbox.open.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<bool>(
              valueListenable: inbox.open,
              builder: (context, open, _) => open
                  ? const SizedBox(
                      width: 380,
                      child: NotificationInboxPopover(),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return inbox;
}

/// Not pumpAndSettle: the popover keeps animations ticking.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _reopen(WidgetTester tester, _Inbox inbox) async {
  inbox.open.value = false;
  await _settle(tester);
  inbox.open.value = true;
  await _settle(tester);
}

/// The section header, found even while scrolled out of view: the panel is
/// a sliver list, which reports what's past its edge as offstage.
final _logStats = find.text('Log stats', skipOffstage: false);

/// The popover's own scroll region — the outermost [Scrollable].
Rect _viewport(WidgetTester tester) =>
    tester.getRect(find.byType(Scrollable).first);

void main() {
  testWidgets('stays open, or closed, across popovers', (tester) async {
    final inbox = await _pumpInbox(tester);
    expect(find.text('No trackers yet.'), findsNothing);
    expect(await inbox.persisted(), isFalse);

    await tester.tap(_logStats);
    await _settle(tester);
    expect(find.text('No trackers yet.'), findsOneWidget);
    expect(await inbox.persisted(), isTrue);

    await _reopen(tester, inbox);
    expect(find.text('No trackers yet.'), findsOneWidget);

    await tester.tap(_logStats);
    await _settle(tester);
    expect(await inbox.persisted(), isFalse);

    await _reopen(tester, inbox);
    expect(find.text('No trackers yet.'), findsNothing);
  });

  testWidgets('toggling never republishes settings', (tester) async {
    // Every page in the shell watches settings, so a publish per toggle
    // rebuilt the whole app mid-scroll.
    final inbox = await _pumpInbox(tester);
    var publishes = 0;
    final sub = inbox.container.listen(settingsProvider, (_, _) => publishes++);
    addTearDown(sub.close);

    await tester.tap(_logStats);
    await _settle(tester);
    await tester.tap(_logStats);
    await _settle(tester);
    expect(publishes, 0);
  });

  testWidgets('a settings save from an older copy leaves it open', (
    tester,
  ) async {
    final inbox = await _pumpInbox(tester);
    final stale = await inbox.container
        .read(settingsRepositoryProvider)
        .getSettings();
    await tester.tap(_logStats);
    await _settle(tester);

    await inbox.container.read(settingsProvider.notifier).saveSettings(stale);
    await _settle(tester);
    expect(await inbox.persisted(), isTrue);
    expect(find.text('No trackers yet.'), findsOneWidget);
  });

  testWidgets('survives a restart', (tester) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final first = await _pumpInbox(tester, db: db);
    await tester.tap(_logStats);
    await _settle(tester);
    expect(await first.persisted(), isTrue);

    // A fresh container over the same database: nothing cached survives.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpInbox(tester, db: db);
    expect(find.text('No trackers yet.'), findsOneWidget);
  });

  testWidgets('opening scrolls the section bottom into view', (tester) async {
    await _pumpInbox(tester, tasks: 15, trackers: 2);
    final viewport = _viewport(tester);
    expect(
      tester.getRect(_logStats).top,
      greaterThan(viewport.bottom),
      reason: 'starts below the fold',
    );

    // Scrolled only as far as the header, which leaves it at the very
    // bottom with the body opening below the fold.
    await tester.ensureVisible(_logStats);
    await _settle(tester);
    await tester.tap(_logStats);
    await _settle(tester);

    final save = tester.getRect(find.text('Save'));
    expect(save.bottom, lessThanOrEqualTo(viewport.bottom));
    // Only the section's own bottom padding below its last row.
    expect(viewport.bottom - save.bottom, lessThan(20));
  });

  testWidgets('scrolls with the growth, not after it', (tester) async {
    await _pumpInbox(tester, tasks: 15, trackers: 2);
    await tester.ensureVisible(_logStats);
    await _settle(tester);
    // The first open of the popover, rows never yet shown: their values
    // were loaded while the section sat closed, so the body doesn't resize
    // again as they arrive — which made AnimatedSize snap open in a frame.
    //
    // The panel is already at its max height, so every frame of the 220ms
    // open should carry the header up — a scroll deferred until the body
    // settles held it still for the whole animation, then jumped.
    final tops = [tester.getRect(_logStats).top];
    await tester.tap(_logStats);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      tops.add(tester.getRect(_logStats).top);
    }
    for (var i = 2; i < tops.length; i++) {
      expect(tops[i], lessThan(tops[i - 1]), reason: 'frame $i: $tops');
    }
  });

  testWidgets('a section taller than the popover scrolls to its header', (
    tester,
  ) async {
    await _pumpInbox(tester, tasks: 15, trackers: 20);
    await tester.ensureVisible(_logStats);
    await _settle(tester);
    await tester.tap(_logStats);
    await _settle(tester);

    final viewport = _viewport(tester);
    final header = tester.getRect(_logStats);
    expect(header.top, greaterThanOrEqualTo(viewport.top));
    expect(header.top - viewport.top, lessThan(20));
  });

  testWidgets("the date opens Voyager's picker, which can't go past today", (
    tester,
  ) async {
    await _pumpInbox(tester);
    await tester.tap(_logStats);
    await _settle(tester);
    final date = find.byIcon(PhosphorIconsRegular.calendar);

    await tester.tap(date);
    await _settle(tester);
    expect(find.byType(DateSelectorPopover), findsOneWidget);
    // Tomorrow is greyed out, and the highlight stops at today.
    await tester.tap(find.text('Tomorrow'));
    await _settle(tester);
    expect(find.byType(DateSelectorPopover), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(find.byType(DateSelectorPopover), findsNothing);
    expect(find.byTooltip('Jump to today'), findsNothing);

    await tester.tap(date);
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(find.byType(DateSelectorPopover), findsNothing);
    expect(find.byTooltip('Jump to today'), findsOneWidget);
  });
}

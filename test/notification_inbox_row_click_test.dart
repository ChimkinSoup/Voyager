// Clicking an inbox row opens what it stands for: a task in the To-Do editor,
// an event in the Calendar's month view with its editor open, a bill in its
// Log payment sheet, and "Backups failing" in Settings at the backup tiles. The Calendar
// side of the reveal is pinned in calendar_overlay_page_test.dart; this pins
// the popover's — the request it sends, and where it navigates — and the
// Settings side.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';
import 'package:voyager/features/settings/settings_page.dart';
import 'package:voyager/features/shell/reveal_request.dart';

import 'fakes/fake_weather_api_client.dart';

/// Backups that have been failing for days. Never started, so no timers.
class _FailingBackups extends AutoBackupService {
  _FailingBackups()
    : super(
        directory: () async => Directory.systemTemp,
        exporter: () => throw UnimplementedError(),
        importer: () => throw UnimplementedError(),
        freeBytes: (_) async => null,
      );

  static const _failing = AutoBackupStatus(
    enabled: true,
    backupCount: 0,
    snapshotCount: 0,
    totalBytes: 0,
    health: AutoBackupHealth.attention,
    detail: 'The disk is full',
    failing: true,
  );

  @override
  AutoBackupStatus? get status => _failing;

  @override
  Future<AutoBackupStatus> refreshStatus() async => _failing;
}

Future<ProviderContainer> _container(
  WidgetTester tester, {
  bool failingBackups = false,
}) async {
  tester.view.physicalSize = const Size(380, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      if (failingBackups)
        autoBackupServiceProvider.overrideWith((ref) => _FailingBackups()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  // Not pumpAndSettle: the popover keeps animations ticking while the
  // providers resolve.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _pumpInbox(
  WidgetTester tester,
  ProviderContainer container,
) async {
  Widget page(String name) => Scaffold(body: Text(name));
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 380,
                    child: NotificationInboxPopover(),
                  ),
                ),
              ),
              child: const Text('bell'),
            ),
          ),
        ),
      ),
      GoRoute(path: '/todo', builder: (_, _) => page('To-Do page')),
      GoRoute(path: '/calendar', builder: (_, _) => page('Calendar page')),
      GoRoute(path: '/settings', builder: (_, _) => page('Settings page')),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: VoyagerTheme.dark(),
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('bell'));
  await _settle(tester);
}

Future<void> _seedTask(ProviderContainer container) async {
  final now = utcNow();
  final repo = container.read(todoRepositoryProvider);
  await repo.upsertList(
    TodoListModel(id: 'list', createdAt: now, updatedAt: now, name: 'L'),
  );
  await repo.upsertTask(
    TodoTask(
      id: 'task',
      createdAt: now,
      updatedAt: now,
      listId: 'list',
      title: 'File taxes',
      dueDate: DateTime.now(),
      sortOrder: 0,
    ),
  );
}

void main() {
  testWidgets('clicking a task row opens it in To-Do', (tester) async {
    final container = await _container(tester);
    await _seedTask(container);
    await _pumpInbox(tester, container);

    await tester.tap(find.text('File taxes'));
    await _settle(tester);

    final request = container.read(revealRequestProvider);
    expect(request?.type, RevealTargetType.task);
    expect(request?.task?.id, 'task');
    expect(find.byType(NotificationInboxPopover), findsNothing);
    expect(find.text('To-Do page'), findsOneWidget);
  });

  testWidgets('ticking a task row completes it without leaving the inbox', (
    tester,
  ) async {
    final container = await _container(tester);
    await _seedTask(container);
    await _pumpInbox(tester, container);

    await tester.tap(find.byType(VoyagerCheckbox));
    await _settle(tester);

    expect(container.read(revealRequestProvider), isNull);
    expect(find.text('To-Do page'), findsNothing);
  });

  testWidgets(
    'clicking a repeating event row opens the occurrence, not the anchor',
    (tester) async {
      final container = await _container(tester);
      final now = DateTime.now();
      // Today's occurrence starts in half an hour; the series began a month
      // ago, so revealing the anchor would open last month.
      final soon = now.add(const Duration(minutes: 30));
      final anchor = DateTime(
        soon.year,
        soon.month,
        soon.day - 30,
        soon.hour,
        soon.minute,
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
              title: 'Standup',
              start: anchor,
              end: anchor.add(const Duration(hours: 1)),
              isFullDay: false,
              recurrence: const RecurrenceRule(
                frequency: EventRecurrence.daily,
              ),
            ),
          );
      await _pumpInbox(tester, container);

      await tester.tap(find.text('Standup'));
      await _settle(tester);

      final request = container.read(revealRequestProvider);
      expect(request?.type, RevealTargetType.event);
      expect(request?.day, DateTime(soon.year, soon.month, soon.day));
      expect(find.text('Calendar page'), findsOneWidget);
    },
  );

  testWidgets('clicking a bill row opens Log payment', (tester) async {
    final container = await _container(tester);
    // The sheet wants more room than the inbox tests' narrow window.
    tester.view.physicalSize = const Size(900, 800);
    final now = utcNow();
    await container
        .read(financeRepositoryProvider)
        .upsertSubscription(
          Subscription(
            id: newId(),
            createdAt: now,
            updatedAt: now,
            name: 'Rent',
            amountCents: 129900,
            period: BillingPeriod.monthly,
            anchorDueDate: DateTime.now(),
          ),
        );
    await _pumpInbox(tester, container);

    await tester.tap(find.text('Rent'));
    await _settle(tester);

    // A new expense for the bill, not the subscription's editor.
    expect(find.text('New transaction'), findsOneWidget);
    expect(find.text('Edit subscription'), findsNothing);
  });

  testWidgets('clicking Backups failing opens Settings at the backups', (
    tester,
  ) async {
    final container = await _container(tester, failingBackups: true);
    await _pumpInbox(tester, container);

    await tester.tap(find.text('Backups failing'));
    await _settle(tester);

    expect(container.read(revealAutoBackupRequestProvider), isTrue);
    expect(find.byType(NotificationInboxPopover), findsNothing);
    expect(find.text('Settings page'), findsOneWidget);
  });

  group('Settings answers the backup reveal', () {
    // Semantics off: SettingsPage mounted outside the shell hands the
    // semantics pass a nested viewport with a non-finite rect (see
    // dark_theme_parity_test.dart).
    Future<void> pumpSettings(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await _settle(tester);
    }

    bool onScreen(WidgetTester tester) {
      final rect = tester.getRect(
        find.text('Automatic backups', skipOffstage: false),
      );
      return rect.top >= 0 && rect.bottom <= 640;
    }

    testWidgets(
      'a request made before Settings opens',
      semanticsEnabled: false,
      (tester) async {
        final container = await _container(tester, failingBackups: true);
        container.read(revealAutoBackupRequestProvider.notifier).state = true;

        await pumpSettings(tester, container);

        expect(onScreen(tester), isTrue);
        expect(container.read(revealAutoBackupRequestProvider), isFalse);
      },
    );

    testWidgets(
      'a request made while Settings is open',
      semanticsEnabled: false,
      (tester) async {
        final container = await _container(tester, failingBackups: true);
        await pumpSettings(tester, container);
        expect(onScreen(tester), isFalse);

        container.read(revealAutoBackupRequestProvider.notifier).state = true;
        await _settle(tester);

        expect(onScreen(tester), isTrue);
        expect(container.read(revealAutoBackupRequestProvider), isFalse);
      },
    );
  });
}

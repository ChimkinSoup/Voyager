// The due-reminder stickies sit above every navigator, so they step aside
// while a dialog or popover is open (BUG-041). A card an OS notification
// click asks for meanwhile still shows through, or the click would look like
// it did nothing.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/reminder_sticky_stack.dart';
import 'package:voyager/routing/popup_route_observer.dart';

class _DueEngine extends ReminderEngine {
  _DueEngine(AppDatabase db)
    : super(
        repository: DriftReminderRepository(db),
        os: NoopReminderOsNotifier(),
        deviceId: 'device',
        onStatesWritten: () {},
        onRulesWritten: () {},
        onLogWritten: (_) {},
      );

  @override
  List<ReminderSourceView> get due => [
    for (final title in ['first', 'second'])
      ReminderSourceView(
        sourceKey: 'rule:$title',
        sourceKind: ReminderSourceKind.scheduledRule,
        sourceId: title,
        title: title,
        evaluation: null,
        targetsThisDevice: true,
      ),
  ];
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDown(PopupRouteObserver.reset);

  testWidgets('stickies hide under a popup; a clicked one shows through', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final engine = _DueEngine(db);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          reminderEngineProvider.overrideWith((ref) => engine),
        ],
        child: MaterialApp(
          navigatorObservers: [PopupRouteObserver()],
          builder: (context, child) =>
              Stack(children: [child!, const ReminderStickyStack()]),
          home: const Scaffold(body: Text('page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);

    showDialog<void>(
      context: tester.element(find.text('page')),
      builder: (_) => const Text('dialog'),
    );
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);

    engine.focus('rule:second');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);

    // Closing the popup brings the rest back, and the next popup hides all.
    Navigator.of(tester.element(find.text('dialog'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    showDialog<void>(
      context: tester.element(find.text('page')),
      builder: (_) => const Text('dialog'),
    );
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);

    // A popup opened over another hides a clicked card too.
    engine.focus('rule:second');
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    showDialog<void>(
      context: tester.element(find.text('dialog')),
      builder: (_) => const Text('nested'),
    );
    await tester.pumpAndSettle();
    expect(find.text('nested'), findsOneWidget);
    expect(find.text('second'), findsNothing);
  });
}

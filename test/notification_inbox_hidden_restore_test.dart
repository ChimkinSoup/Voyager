// Recovering a dismissed inbox item (INBOX_HIDDEN_RESTORE_HLD.md): the header
// only *shows* Hidden, restoring lives inside it, and a dismiss or Clear all
// raises one Undo offer that grows while the user keeps dismissing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

/// Tall enough that nothing in these tests needs scrolling to be tapped.
const Size _kWindow = Size(380, 1000);

class _Inbox {
  _Inbox(this.container, this.open);

  final ProviderContainer container;

  /// Flip to false to close the popover while the app — and its root overlay,
  /// where the toast lives — stays up.
  final ValueNotifier<bool> open;

  Future<Set<String>> dismissed() =>
      container.read(notificationRepositoryProvider).listDismissals();

  Future<List<String>> feedKeys() async => [
    for (final item in await container.read(notificationFeedProvider.future))
      item.dismissalKey,
  ];
}

Future<_Inbox> _pumpInbox(
  WidgetTester tester, {
  List<String> tasks = const [],
  bool withBill = false,
  bool withNote = false,
  int hideFirst = 0,
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
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  final now = utcNow();
  if (withNote) {
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
  }
  if (tasks.isNotEmpty) {
    await container
        .read(todoRepositoryProvider)
        .upsertList(
          TodoListModel(id: 'list', createdAt: now, updatedAt: now, name: 'L'),
        );
    for (var i = 0; i < tasks.length; i++) {
      await container
          .read(todoRepositoryProvider)
          .upsertTask(
            TodoTask(
              id: newId(),
              createdAt: now,
              updatedAt: now,
              listId: 'list',
              title: tasks[i],
              dueDate: DateTime.now(),
              sortOrder: i,
            ),
          );
    }
  }
  if (withBill) {
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
  }

  final inbox = _Inbox(container, ValueNotifier(true));
  addTearDown(inbox.open.dispose);
  if (hideFirst > 0) {
    final repo = container.read(notificationRepositoryProvider);
    for (final key in (await inbox.feedKeys()).take(hideFirst)) {
      await repo.dismiss(key);
    }
    container.invalidate(notificationDismissalsProvider);
  }

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

/// Not pumpAndSettle: the popover and the toast keep animations ticking.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Finder _dismissOf(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
  matching: find.byIcon(PhosphorIconsRegular.x),
);

Finder get _hiddenTrigger => find
    .ancestor(
      of: find.textContaining('Hidden ('),
      matching: find.byType(Stack),
    )
    .first;

void main() {
  testWidgets('the header shows hidden and never restores', (tester) async {
    final inbox = await _pumpInbox(tester, tasks: ['A', 'B'], hideFirst: 1);
    final before = await inbox.dismissed();
    expect(before, hasLength(1));

    expect(find.byTooltip('Show hidden'), findsOneWidget);
    expect(find.text('Restore all'), findsNothing);
    expect(find.byTooltip('Restore all'), findsNothing);

    await tester.tap(find.byTooltip('Show hidden'));
    await _settle(tester);
    expect(find.text('Restore all'), findsOneWidget, reason: 'expanded');
    expect(await inbox.dismissed(), before, reason: 'nothing was restored');

    // A second press scrolls, but does not collapse.
    await tester.tap(find.byTooltip('Show hidden'));
    await _settle(tester);
    expect(find.text('Restore all'), findsOneWidget);
  });

  testWidgets('Show hidden leaves the header when nothing is hidden', (
    tester,
  ) async {
    await _pumpInbox(tester, tasks: ['A']);
    expect(find.byTooltip('Show hidden'), findsNothing);
    expect(find.byTooltip('Clear all'), findsOneWidget);
  });

  testWidgets('Restore all only while open with nothing selected', (
    tester,
  ) async {
    final inbox = await _pumpInbox(tester, tasks: ['A', 'B'], hideFirst: 2);

    expect(find.text('Hidden (2)'), findsOneWidget);
    expect(find.text('Restore all'), findsNothing, reason: 'collapsed');

    await tester.tap(_hiddenTrigger);
    await _settle(tester);
    expect(find.text('Restore all'), findsOneWidget);

    await tester.tap(find.text('A'));
    await _settle(tester);
    expect(find.text('Restore (1)'), findsOneWidget);
    expect(find.text('Restore all'), findsNothing);

    await tester.tap(find.text('A'));
    await _settle(tester);
    await tester.tap(find.text('Restore all'));
    await _settle(tester);
    expect(await inbox.dismissed(), isEmpty);
    expect(find.textContaining('Hidden ('), findsNothing);
  });

  testWidgets('closing Hidden slides the rows out rather than dropping them', (
    tester,
  ) async {
    await _pumpInbox(tester, tasks: ['A', 'B'], hideFirst: 2);
    await tester.tap(_hiddenTrigger);
    await _settle(tester);
    final openHeight = tester.getSize(find.byType(NotificationInboxPopover));

    await tester.tap(_hiddenTrigger);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(find.text('A'), findsOneWidget, reason: 'still there mid-close');
    final midHeight = tester.getSize(find.byType(NotificationInboxPopover));
    expect(midHeight.height, lessThan(openHeight.height));

    await _settle(tester);
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsNothing);
  });

  testWidgets('a hidden row carries the feed subtitle and glyph, no dot', (
    tester,
  ) async {
    await _pumpInbox(tester, tasks: ['A'], withBill: true, hideFirst: 2);
    await tester.tap(_hiddenTrigger);
    await _settle(tester);

    expect(find.text('A'), findsOneWidget);
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget, reason: 'the task due label');
    expect(find.text('${formatCents(129900)} · Today'), findsOneWidget);
    // Scoped to the row: the empty feed's "All caught up" is a checkCircle too.
    Finder rowIcon(String title, IconData icon) => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
      matching: find.byIcon(icon),
    );
    expect(rowIcon('A', PhosphorIconsRegular.checkCircle), findsOneWidget);
    expect(
      rowIcon('Rent', PhosphorIconsRegular.currencyDollar),
      findsOneWidget,
    );
    expect(find.byType(NotificationUrgencyDot), findsNothing);
  });

  testWidgets('a dismiss offers Undo, which puts the item back', (
    tester,
  ) async {
    final inbox = await _pumpInbox(tester, tasks: ['Buy milk']);

    await tester.tap(_dismissOf('Buy milk'));
    await _settle(tester);
    expect(find.text('Hidden "Buy milk"'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsRegular.eyeSlash), findsOneWidget);
    expect(find.textContaining('Deleted'), findsNothing);
    expect(await inbox.dismissed(), hasLength(1));

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(await inbox.dismissed(), isEmpty);
    expect(_dismissOf('Buy milk'), findsOneWidget, reason: 'back in the feed');
  });

  testWidgets('dismiss is stored even if the popover closes mid-exit', (
    tester,
  ) async {
    final inbox = await _pumpInbox(tester, tasks: ['A']);

    await tester.tap(_dismissOf('A'));
    // Next frame only — do not wait out the exit animation. Closing here used
    // to cancel the write when dismiss ran after `_exit.forward()`.
    await tester.pump();
    inbox.open.value = false;
    await tester.pump();
    expect(await inbox.dismissed(), hasLength(1));
    expect(find.text('Hidden "A"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(await inbox.dismissed(), isEmpty);
  });

  testWidgets('dismisses inside the dwell join one offer', (tester) async {
    final inbox = await _pumpInbox(tester, tasks: ['A', 'B']);

    await tester.tap(_dismissOf('A'));
    await _settle(tester);
    await tester.tap(_dismissOf('B'));
    await _settle(tester);
    expect(find.text('Hidden 2 items'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(await inbox.dismissed(), isEmpty);
  });

  testWidgets('Clear all is one offer, and joins a standing streak', (
    tester,
  ) async {
    final inbox = await _pumpInbox(tester, tasks: ['A', 'B', 'C']);

    await tester.tap(_dismissOf('A'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Clear all'));
    await _settle(tester);
    expect(find.text('Hidden 3 items'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(await inbox.dismissed(), hasLength(3));

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(await inbox.dismissed(), isEmpty);
  });

  testWidgets('Undo still works once the popover has closed', (tester) async {
    final inbox = await _pumpInbox(tester, tasks: ['A']);

    await tester.tap(_dismissOf('A'));
    await _settle(tester);
    inbox.open.value = false;
    await _settle(tester);
    expect(find.byType(NotificationInboxPopover), findsNothing);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(await inbox.dismissed(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Undo skips an item already restored from Hidden', (
    tester,
  ) async {
    final inbox = await _pumpInbox(tester, tasks: ['A']);
    final key = (await inbox.feedKeys()).single;
    final repo = inbox.container.read(notificationRepositoryProvider);

    await tester.tap(_dismissOf('A'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Show hidden'));
    await _settle(tester);
    await tester.tap(find.text('Restore all'));
    await _settle(tester);
    final restored = await repo.getDismissal(key);
    expect(restored!.isDismissed, isFalse);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    final after = await repo.getDismissal(key);
    expect(after!.isDismissed, isFalse, reason: 'Undo never re-hides');
    expect(after.version, restored.version, reason: 'and writes nothing');
  });

  testWidgets('pinned-note delete still says Deleted and skips Hidden', (
    tester,
  ) async {
    await _pumpInbox(tester, withNote: true);

    await tester.tap(find.byIcon(PhosphorIconsRegular.x));
    await _settle(tester);
    expect(find.text('Deleted "Water the plants"'), findsOneWidget);
    expect(find.byTooltip('Show hidden'), findsNothing);
    expect(find.textContaining('Hidden'), findsNothing);
  });
}

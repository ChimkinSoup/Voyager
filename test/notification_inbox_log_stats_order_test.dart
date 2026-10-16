// The inbox's Log stats list: in the user's own order, dragged by a held
// press on a tracker's name, saved in settings and synced with them; weekly,
// monthly and yearly trackers listed only while their period is unlogged.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

var _created = 0;

StatisticTracker _tracker(
  String name, {
  TrackerCadence cadence = TrackerCadence.daily,
}) {
  final now = utcNow();
  return StatisticTracker(
    id: name,
    // Distinct, so the fallback order between untouched trackers is fixed.
    createdAt: now.add(Duration(seconds: _created++)),
    updatedAt: now,
    name: name,
    type: TrackerType.boolean,
    cadence: cadence,
  );
}

Future<ProviderContainer> _container(
  WidgetTester tester,
  List<StatisticTracker> trackers, {
  List<String> order = const [],
}) async {
  tester.view.physicalSize = const Size(380, 800);
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
  for (final tracker in trackers) {
    await container.read(trackerRepositoryProvider).upsertTracker(tracker);
  }
  await container.read(settingsProvider.future);
  if (order.isNotEmpty) {
    await container
        .read(settingsProvider.notifier)
        .saveInboxTrackerOrder(order);
  }
  return container;
}

/// Mounts a fresh inbox over [container]. The section stays open once
/// opened, so only the first showing taps its header.
Future<void> _show(
  WidgetTester tester,
  ProviderContainer container, {
  bool open = true,
}) async {
  await container.read(trackersProvider.future);
  await tester.pumpWidget(const SizedBox.shrink());
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
  await _settle(tester);
  if (!open) return;
  await tester.ensureVisible(find.text('Log stats'));
  await _settle(tester);
  await tester.tap(find.text('Log stats'));
  await _settle(tester);
}

/// Not pumpAndSettle: the popover keeps animations ticking.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// Which of [names] are listed, top to bottom.
List<String> _shown(WidgetTester tester, List<String> names) {
  return names.where((n) => find.text(n).evaluate().isNotEmpty).toList()..sort(
    (a, b) => tester
        .getCenter(find.text(a))
        .dy
        .compareTo(tester.getCenter(find.text(b)).dy),
  );
}

/// Holds [name] past the drag delay, then drags it to [dy] past the centre
/// of [target]'s name.
Future<void> _drag(
  WidgetTester tester,
  String name,
  String target, {
  required double dy,
}) async {
  final from = tester.getCenter(find.text(name));
  final to = tester.getCenter(find.text(target)) + Offset(0, dy);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 300));
  for (var i = 1; i <= 10; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

DateTime _currentPeriod(StatisticTracker tracker) => PeriodicPromptService()
    .trackerPeriodStartFor(DateTime.now(), tracker.cadence);

/// Logs [tracker] for the period today falls in.
Future<void> _log(ProviderContainer container, StatisticTracker tracker) async {
  final period = _currentPeriod(tracker);
  final now = utcNow();
  await container
      .read(trackerRepositoryProvider)
      .upsertValue(
        TrackerValue(
          id: trackerValueId(tracker.id, period),
          createdAt: now,
          updatedAt: now,
          version: 1,
          trackerId: tracker.id,
          periodStart: period,
          boolValue: true,
        ),
      );
  container.invalidate(trackerValuesProvider(tracker.id));
}

Future<void> _unlog(
  ProviderContainer container,
  StatisticTracker tracker,
) async {
  await container
      .read(trackerRepositoryProvider)
      .softDeleteValue(trackerValueId(tracker.id, _currentPeriod(tracker)));
  container.invalidate(trackerValuesProvider(tracker.id));
}

Future<List<String>> _saved(ProviderContainer container) async =>
    (await container.read(settingsRepositoryProvider).getSettings())
        .inboxTrackerOrder;

void main() {
  testWidgets('lists trackers by their saved inbox position', (tester) async {
    final container = await _container(
      tester,
      [_tracker('A'), _tracker('B'), _tracker('C')],
      order: ['B', 'C', 'A'],
    );
    await _show(tester, container);
    expect(_shown(tester, ['A', 'B', 'C']), ['B', 'C', 'A']);
  });

  testWidgets('a tracker the saved order doesn\'t name goes last', (
    tester,
  ) async {
    final container = await _container(
      tester,
      [_tracker('New'), _tracker('A'), _tracker('B')],
      order: ['B', 'A'],
    );
    await _show(tester, container);
    expect(_shown(tester, ['New', 'A', 'B']), ['B', 'A', 'New']);
  });

  testWidgets('a held drag on a name moves the row and saves the order', (
    tester,
  ) async {
    final container = await _container(tester, [
      _tracker('A'),
      _tracker('B'),
      _tracker('C'),
    ]);
    await _show(tester, container);
    expect(_shown(tester, ['A', 'B', 'C']), ['A', 'B', 'C']);

    await _drag(tester, 'A', 'C', dy: 20);

    expect(_shown(tester, ['A', 'B', 'C']), ['B', 'C', 'A']);
    expect(await _saved(container), ['B', 'C', 'A']);
  });

  testWidgets('a drag leaves the trackers themselves untouched', (
    tester,
  ) async {
    final container = await _container(tester, [
      _tracker('A'),
      _tracker('B'),
      _tracker('C'),
    ]);
    final repo = container.read(trackerRepositoryProvider);
    Future<Map<String, int>> versions() async => {
      for (final t in await repo.listTrackers()) t.id: t.version,
    };
    final before = await versions();
    await _show(tester, container);

    await _drag(tester, 'A', 'C', dy: 20);

    expect(_shown(tester, ['A', 'B', 'C']), ['B', 'C', 'A']);
    expect(await versions(), before);
  });

  // Every page in the shell watches settings, so a publish per drop rebuilt
  // the whole app as the row landed.
  testWidgets('a drag never republishes settings', (tester) async {
    final container = await _container(tester, [
      _tracker('A'),
      _tracker('B'),
      _tracker('C'),
    ]);
    await _show(tester, container);
    var publishes = 0;
    final sub = container.listen(settingsProvider, (_, _) => publishes++);
    addTearDown(sub.close);

    await _drag(tester, 'A', 'C', dy: 20);

    expect(_shown(tester, ['A', 'B', 'C']), ['B', 'C', 'A']);
    expect(await _saved(container), ['B', 'C', 'A']);
    expect(publishes, 0);
  });

  testWidgets('a settings save from an older copy keeps the dragged order', (
    tester,
  ) async {
    final container = await _container(tester, [
      _tracker('A'),
      _tracker('B'),
      _tracker('C'),
    ]);
    final stale = await container.read(settingsProvider.future);
    await _show(tester, container);
    await _drag(tester, 'A', 'C', dy: 20);

    await container
        .read(settingsProvider.notifier)
        .saveSettings(stale.copyWith(showQuotes: !stale.showQuotes));
    await _settle(tester);

    expect(_shown(tester, ['A', 'B', 'C']), ['B', 'C', 'A']);
    expect(await _saved(container), ['B', 'C', 'A']);
  });

  testWidgets('an order pulled from another device shows at once', (
    tester,
  ) async {
    final container = await _container(tester, [
      _tracker('A'),
      _tracker('B'),
      _tracker('C'),
    ]);
    await _show(tester, container);
    expect(_shown(tester, ['A', 'B', 'C']), ['A', 'B', 'C']);

    // What a pull does: write the merged row, then reload the settings.
    final repo = container.read(settingsRepositoryProvider);
    final stored = await repo.getSettings();
    await repo.saveSettings(
      stored.copyWith(inboxTrackerOrder: const ['C', 'A', 'B']),
      recordLocalActivity: false,
    );
    container.invalidate(settingsProvider);
    await _settle(tester);

    expect(_shown(tester, ['A', 'B', 'C']), ['C', 'A', 'B']);
  });

  testWidgets('dragging a row to the bottom edge scrolls the panel', (
    tester,
  ) async {
    final names = [for (var i = 0; i < 24; i++) 'T$i'];
    final container = await _container(tester, [
      for (final name in names) _tracker(name),
    ]);
    await _show(tester, container);
    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(position.pixels));
    final before = position.pixels;
    final lastOnScreen = names.lastIndexWhere(
      (n) => find.text(n).evaluate().isNotEmpty,
    );
    expect(lastOnScreen, lessThan(names.length - 1));

    final from = tester.getCenter(find.text('T0'));
    final to = Offset(from.dx, tester.getRect(scrollable).bottom - 4);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Held at the edge.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.pixels, greaterThan(before));

    await gesture.up();
    await _settle(tester);
    // Dropped below every row that was on screen when the drag began.
    expect((await _saved(container)).indexOf('T0'), greaterThan(lastOnScreen));
  });

  testWidgets('weekly, monthly and yearly trackers show until logged', (
    tester,
  ) async {
    final weekly = _tracker('Weekly', cadence: TrackerCadence.weekly);
    final monthly = _tracker('Monthly', cadence: TrackerCadence.monthly);
    final yearly = _tracker('Yearly', cadence: TrackerCadence.yearly);
    final container = await _container(tester, [
      _tracker('Daily'),
      weekly,
      monthly,
      yearly,
    ]);
    final names = ['Daily', 'Weekly', 'Monthly', 'Yearly'];
    await _log(container, monthly);
    await _show(tester, container);
    expect(_shown(tester, names), ['Daily', 'Weekly', 'Yearly']);
    expect(await container.read(pendingStatEntriesProvider.future), 3);

    // Logged while listed: the row stays for as long as the date is up.
    await _log(container, weekly);
    container.invalidate(pendingStatEntriesProvider);
    await _settle(tester);
    expect(_shown(tester, names), ['Daily', 'Weekly', 'Yearly']);
    expect(await container.read(pendingStatEntriesProvider.future), 2);

    // Gone the next time the inbox opens.
    await _show(tester, container, open: false);
    expect(_shown(tester, names), ['Daily', 'Yearly']);
  });

  testWidgets('trackers moved on days apart keep their places together', (
    tester,
  ) async {
    final weekly = _tracker('Weekly', cadence: TrackerCadence.weekly);
    final monthly = _tracker('Monthly', cadence: TrackerCadence.monthly);
    final container = await _container(tester, [
      _tracker('D1'),
      _tracker('D2'),
      weekly,
      monthly,
    ]);
    final names = ['D1', 'D2', 'Weekly', 'Monthly'];

    // A day the weekly tracker is due and the monthly one isn't.
    await _log(container, monthly);
    await _show(tester, container);
    expect(_shown(tester, names), ['D1', 'D2', 'Weekly']);
    await _drag(tester, 'Weekly', 'D1', dy: -20);
    expect(_shown(tester, names), ['Weekly', 'D1', 'D2']);

    // The other way round.
    await _log(container, weekly);
    await _unlog(container, monthly);
    await _show(tester, container, open: false);
    expect(_shown(tester, names), ['D1', 'D2', 'Monthly']);
    await _drag(tester, 'Monthly', 'D1', dy: -20);
    expect(_shown(tester, names), ['Monthly', 'D1', 'D2']);

    // Both due: both above the daily trackers.
    await _unlog(container, weekly);
    await _show(tester, container, open: false);
    expect(_shown(tester, names), ['Weekly', 'Monthly', 'D1', 'D2']);
    expect(await _saved(container), ['Weekly', 'Monthly', 'D1', 'D2']);
  });

  test('the inbox order syncs with settings', () {
    final remote = settingsToFirestore(
      AppSettings(inboxTrackerOrder: const ['B', 'A'], updatedAt: utcNow()),
    );
    expect(
      mergeSettingsFromRemote(remote, const AppSettings()).inboxTrackerOrder,
      ['B', 'A'],
    );
  });
}

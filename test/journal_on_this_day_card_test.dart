// The On this day card and its ledge (ON_THIS_DAY_HLD.md §5), mounted over a
// stand-in page: a tappable list and a focused text field, which is all the
// card has to stay out of the way of. Built over a bare MaterialApp, not
// AppShell.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/on_this_day_overlay.dart';

import 'fakes/fake_weather_api_client.dart';

const _journalId = 'journal';
final _today = DateTime(2026, 9, 24);

class _Harness {
  _Harness(this.db, this.container);

  final AppDatabase db;
  final ProviderContainer container;
  final opened = <String>[];
  final listTaps = <int>[];
  final fieldKeys = <LogicalKeyboardKey>[];
  final fieldFocus = FocusNode();
}

Future<_Harness> _setUp(
  WidgetTester tester, {
  int matches = 2,
  bool showMood = true,
  bool showWeather = true,
  bool onScreen = true,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJournalRepository(db);
  final created = DateTime.utc(2020);
  await repo.upsertJournal(
    Journal(
      id: _journalId,
      name: 'Diary',
      createdAt: created,
      updatedAt: created,
      showMood: showMood,
      showWeather: showWeather,
      onThisDayCadence: OnThisDayCadence.yearly,
    ),
  );
  for (var i = 1; i <= matches; i++) {
    final date = DateTime(2026 - i, 9, 24, 12).toUtc();
    await repo.upsertEntry(
      JournalEntry(
        id: 'memory-$i',
        journalId: _journalId,
        title: 'Memory $i',
        body: 'Body $i',
        entryDate: date,
        createdAt: date,
        updatedAt: date,
        mood: 7,
        weatherIcon: 'rain',
      ),
    );
  }
  final nextDay = DateTime(2025, 9, 25, 12).toUtc();
  await repo.upsertEntry(
    JournalEntry(
      id: 'tomorrow',
      journalId: _journalId,
      title: 'A day later',
      body: '',
      entryDate: nextDay,
      createdAt: nextDay,
      updatedAt: nextDay,
    ),
  );

  final harness = _Harness(db, _newContainer(db));
  addTearDown(harness.fieldFocus.dispose);
  await _pump(tester, harness, today: _today, onScreen: onScreen);
  return harness;
}

/// A fresh app run over [db]: nothing held in memory from the last one.
ProviderContainer _newContainer(AppDatabase db) {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  _Harness h, {
  required DateTime today,
  Key? overlayKey,
  bool onScreen = true,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 300,
                    child: ListView(
                      children: [
                        for (var i = 0; i < 3; i++)
                          ListTile(
                            title: Text('row $i'),
                            onTap: () => h.listTaps.add(i),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent) {
                          h.fieldKeys.add(event.logicalKey);
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(focusNode: h.fieldFocus),
                    ),
                  ),
                ],
              ),
              Positioned.fill(
                // The shell keeps pages it has left mounted, with tickers off.
                child: TickerMode(
                  enabled: onScreen,
                  child: OnThisDayOverlay(
                    key: overlayKey,
                    today: today,
                    journalId: _journalId,
                    ready: true,
                    onOpen: h.opened.add,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// Lets the entrance delay run out and the slide finish.
Future<void> _waitForEntrance(WidgetTester tester) async {
  await tester.pump(OnThisDayOverlay.entranceDelay);
  await tester.pumpAndSettle();
}

final _card = find.text('On this day');

/// Out means upright inside the window; tucked, the header is past its right
/// edge and only the card's left strip shows.
bool _isOut(WidgetTester tester) => tester.getRect(_card).right <= 1200;

/// Taps the strip of the tucked card that pokes out of the right edge.
Future<void> _tapEdge(WidgetTester tester) async {
  await tester.tapAt(const Offset(1200 - 14, 72 + 150));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('slides out once, tucks away on outside interaction, and the '
      'ledge brings it back', (tester) async {
    final h = await _setUp(tester);
    expect(_isOut(tester), isFalse);

    await _waitForEntrance(tester);
    expect(_isOut(tester), isTrue);

    // A tap on the list collapses the card and still selects the row.
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
    expect(_isOut(tester), isFalse);
    expect(h.listTaps, [1]);
    expect(_card, findsOneWidget, reason: 'still peeking');
    expect(find.text('2'), findsOneWidget, reason: 'count badge');
    expect(find.text('1y'), findsOneWidget, reason: 'newest is a year back');

    await _tapEdge(tester);
    await tester.pumpAndSettle();
    expect(_isOut(tester), isTrue);

    // Typing into the already-focused editor collapses it, and the key still
    // reaches the editor.
    h.fieldFocus.requestFocus();
    await tester.pump();
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(_isOut(tester), isFalse);
    expect(h.fieldKeys, [LogicalKeyboardKey.keyA]);
    // Reported unhandled, so the engine still delivers the typed character.
    expect(handled, isFalse);

    // Esc from anywhere.
    await _tapEdge(tester);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_isOut(tester), isFalse);

    // A second visit the same day starts as a ledge.
    await _pump(tester, h, today: _today, overlayKey: const ValueKey('again'));
    await _waitForEntrance(tester);
    expect(_isOut(tester), isFalse);
    expect(_card, findsOneWidget);
  });

  testWidgets('✕ hides every match until the app restarts, and the next day '
      'shows its own', (tester) async {
    final h = await _setUp(tester);
    await _waitForEntrance(tester);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(_card, findsNothing);
    expect(find.text('Memory 1'), findsNothing);
    // Nothing persisted: no dismissal rows, so nothing syncs either.
    expect(await DriftNotificationRepository(h.db).listDismissals(), isEmpty);

    // Leaving the page and coming back in the same run keeps it closed.
    await _pump(tester, h, today: _today, overlayKey: const ValueKey('again'));
    await _waitForEntrance(tester);
    expect(_card, findsNothing);

    // A restart the same day brings it back, and it slides out again.
    final restarted = _Harness(h.db, _newContainer(h.db));
    addTearDown(restarted.fieldFocus.dispose);
    await _pump(tester, restarted, today: _today);
    await _waitForEntrance(tester);
    expect(_isOut(tester), isTrue);

    await _pump(tester, h, today: DateTime(2026, 9, 25));
    await _waitForEntrance(tester);
    expect(find.text('A day later'), findsOneWidget);
  });

  testWidgets('Open hands the entry to the page and collapses the card', (
    tester,
  ) async {
    final h = await _setUp(tester);
    await _waitForEntrance(tester);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(h.opened, ['memory-1']);
    expect(_isOut(tester), isFalse);
    expect(_card, findsOneWidget);
  });

  testWidgets('pages through matches, newest first', (tester) async {
    await _setUp(tester, matches: 3);
    await _waitForEntrance(tester);

    expect(find.text('1 of 3'), findsOneWidget);
    expect(find.text('Memory 1'), findsOneWidget);
    expect(find.text('1 year ago · Sep 24'), findsOneWidget);

    await tester.tap(find.byTooltip('Older'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.text('Memory 2'), findsOneWidget);
    expect(find.text('2 years ago · Sep 24'), findsOneWidget);
    expect(_isOut(tester), isTrue, reason: 'paging is inside the card');

    await tester.tap(find.byTooltip('Newer'));
    await tester.pumpAndSettle();
    expect(find.text('Memory 1'), findsOneWidget);
  });

  testWidgets('mood and weather follow the journal toggles', (tester) async {
    await _setUp(tester);
    await _waitForEntrance(tester);
    expect(find.text('Mood 7/10'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsRegular.cloudRain), findsOneWidget);
  });

  testWidgets('mood and weather stay hidden when the journal hides them', (
    tester,
  ) async {
    await _setUp(tester, showMood: false, showWeather: false);
    await _waitForEntrance(tester);
    expect(_isOut(tester), isTrue);
    expect(find.text('Mood 7/10'), findsNothing);
    expect(find.byIcon(PhosphorIconsRegular.cloudRain), findsNothing);
  });

  testWidgets('a lone modifier leaves it out; a shortcut tucks it', (
    tester,
  ) async {
    await _setUp(tester);
    await _waitForEntrance(tester);

    for (final key in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(_isOut(tester), isTrue, reason: '$key alone');
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(_isOut(tester), isFalse);
  });

  testWidgets('Tab never lands inside the card', (tester) async {
    final h = await _setUp(tester);
    await _waitForEntrance(tester);
    h.fieldFocus.requestFocus();
    await tester.pump();

    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<OnThisDayOverlay>(),
        isNull,
        reason: 'Tab $i',
      );
    }
  });

  testWidgets('a scope change while out goes straight to tucked', (
    tester,
  ) async {
    final h = await _setUp(tester);
    await _waitForEntrance(tester);
    expect(_isOut(tester), isTrue);

    await _pump(tester, h, today: DateTime(2026, 9, 25), settle: false);
    await tester.pump();
    expect(find.text('A day later'), findsOneWidget);
    expect(_isOut(tester), isFalse, reason: 'no slide-in of the new memory');

    // The new scope still gets its own entrance.
    await _waitForEntrance(tester);
    expect(_isOut(tester), isTrue);
  });

  testWidgets('off screen, the entrance waits for the page to come back', (
    tester,
  ) async {
    final h = await _setUp(tester, onScreen: false);
    final tucked = tester.getRect(_card);
    await _waitForEntrance(tester);

    // Back on screen, it still waits out the entrance delay before moving.
    await _pump(tester, h, today: _today, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(_card), tucked, reason: 'not started off screen');

    await _waitForEntrance(tester);
    expect(_isOut(tester), isTrue);
  });

  testWidgets('✕ under the mouse leaves no hover nudge behind', (tester) async {
    final h = await _setUp(tester);
    final tucked = tester.getRect(_card);
    await _waitForEntrance(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(_card));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byTooltip('Dismiss')));
    await mouse.down(tester.getCenter(find.byTooltip('Dismiss')));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(_card, findsNothing);
    await mouse.moveTo(const Offset(100, 700));

    await _pump(tester, h, today: DateTime(2026, 9, 25));
    expect(tester.getRect(_card), tucked);
  });
}

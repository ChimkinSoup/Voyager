// Phase 16 Life fixes: the page's figures follow the clock instead of the
// last rebuild (BUG-141), a long value stays inside the canvas at small sizes
// (BUG-142), and Enter in the birth date picker's typed field accepts the date
// (BUG-143).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/life_tracker/life_tracker_page.dart';
import 'package:voyager/features/life_tracker/life_tracker_providers.dart';
import 'package:voyager/features/life_tracker/stat_leader_label.dart';
import 'package:voyager/features/settings/settings_page.dart';

class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

final _birth = DateTime(1990, 6, 15);

/// The Life page with a birth date, under a clock the test moves. Never
/// pumpAndSettle it: the canopy's ticker never stops.
Future<StateController<DateTime>> _pumpLife(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final clock = StateProvider((ref) => DateTime(2026, 10, 1, 21, 38, 10));
  late StateController<DateTime> controller;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettings(AppSettings(birthDate: _birth)),
        ),
        lifeTrackerStatsProvider.overrideWith(
          (ref) async =>
              const LifeTrackerCachedStats(tasksConquered: 0, lifetimeMood: 5),
        ),
        lifeClockProvider.overrideWith((ref) => ref.watch(clock)),
      ],
      child: MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, child) {
              controller = ref.read(clock.notifier);
              return child!;
            },
            child: const LifeTrackerPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return controller;
}

String _value(WidgetTester tester, String suffix) => tester
    .widgetList<StatLeaderLabel>(find.byType(StatLeaderLabel))
    .firstWhere((l) => l.value.endsWith(suffix))
    .value;

void main() {
  group('BUG-141', () {
    testWidgets('the Life clock ticks at the turn of each minute', (
      tester,
    ) async {
      final container = ProviderContainer();
      final seen = <DateTime>[];
      container.listen(
        lifeClockProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(seen.length, greaterThanOrEqualTo(2));
      // Disposed here, not in a tear-down: the next tick's timer has to be
      // gone before the test's own pending-timer check.
      container.dispose();
    });

    testWidgets('the page\'s figures follow the clock', (tester) async {
      final clock = await _pumpLife(tester);
      final before = _value(tester, ' km');
      clock.state = clock.state.add(const Duration(minutes: 1));
      await tester.pump();
      expect(_value(tester, ' km'), isNot(before));
    });
  });

  testWidgets('BUG-142 every figure stays inside the canvas at a small size', (
    tester,
  ) async {
    // The canvas's share of a 720×520 window.
    await _pumpLife(tester, size: const Size(610, 450));
    final canvas = tester.getRect(find.byType(LifeTrackerPage));
    for (final label in tester.widgetList<StatLeaderLabel>(
      find.byType(StatLeaderLabel),
    )) {
      final value = tester.getRect(
        find.descendant(
          of: find.byWidget(label),
          matching: find.text(label.value),
        ),
      );
      expect(value.left, greaterThanOrEqualTo(canvas.left), reason: label.name);
      expect(value.right, lessThanOrEqualTo(canvas.right), reason: label.name);
    }
  });

  group('BUG-143 the birth date picker', () {
    Future<List<AppSettings>> openTypedPicker(WidgetTester tester) async {
      // Tall enough that the Pages tab builds down to the Birth date row.
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _RecordingSettingsRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repo),
            journalsProvider.overrideWith((ref) async => []),
            todoListStatsProvider.overrideWith((ref) async => {}),
            authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
          ],
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.widgetWithText(Tab, 'Pages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Birth date'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      return repo.saved;
    }

    testWidgets(
      'Enter accepts a typed date and closes',
      semanticsEnabled: false,
      (tester) async {
        final saved = await openTypedPicker(tester);
        await tester.enterText(
          find.byType(TextField).last,
          DateFormat.yMd().format(DateTime(1990, 6, 15)),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(saved.last.birthDate, DateTime(1990, 6, 15));
      },
    );

    testWidgets(
      'Enter on a future date says so and stays open',
      semanticsEnabled: false,
      (tester) async {
        final saved = await openTypedPicker(tester);
        await tester.enterText(
          find.byType(TextField).last,
          DateFormat.yMd().format(DateTime.now().add(const Duration(days: 40))),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(find.text('Out of range.'), findsOneWidget);
        expect(saved, isEmpty);
      },
    );
  });
}

class _RecordingSettingsRepository implements SettingsRepository {
  final saved = <AppSettings>[];

  @override
  Future<AppSettings> getSettings() async =>
      saved.isEmpty ? const AppSettings() : saved.last;

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async => saved.add(settings);

  @override
  noSuchMethod(Invocation invocation) => null;
}

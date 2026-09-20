// The reminder floater's window is only a little larger than the pickers the
// editor opens inside it — 484x495 against the date picker's 500x380 — and a
// popover laid out larger than its viewport can only be placed off the edge,
// where it is cut rather than scrolled. That is what took the date picker's
// "Today / Tomorrow / Next Week" row and its month header off the top, and
// half the first weekday column off the left.
//
// Both of the editor's pickers have to come up whole inside the floater, so
// every day of the month can still be reached from the hotkey.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

import 'fakes/fake_weather_api_client.dart';
import 'narrow_window_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  Future<void> pumpFloater(WidgetTester tester) async {
    await loadRealFonts(tester);
    tester.view.physicalSize = kReminderFloaterSize;
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
    final now = DateTime.now().toUtc();
    await container
        .read(reminderRepositoryProvider)
        .upsertDevice(
          DeviceRegistration(
            id: 'this-device',
            createdAt: now,
            updatedAt: now,
            displayName: 'Desktop',
            platform: DevicePlatform.windows,
            lastSeenAt: now,
          ),
        );
    await container.read(settingsProvider.future);
    await container.read(deviceRegistrationsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: scheduledReminderForm(
              onClose: () {},
              leading: const FloaterAppIcon(
                PhosphorIconsRegular.bellRinging,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  /// The floater's window, which the popover has to stay inside of.
  final window = Offset.zero & kReminderFloaterSize;

  void expectInsideWindow(WidgetTester tester, Finder finder, String what) {
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(0.0), reason: '$what off the left');
    expect(rect.top, greaterThanOrEqualTo(0.0), reason: '$what off the top');
    expect(
      rect.right,
      lessThanOrEqualTo(window.right),
      reason: '$what off the right',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(window.bottom),
      reason: '$what off the bottom',
    );
  }

  testWidgets(
    "the Once date picker opens whole inside the floater's window",
    (tester) async {
      await pumpFloater(tester);

      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(PhosphorIconsRegular.clock));
      await tester.pumpAndSettle();

      expectInsideWindow(
        tester,
        find.byType(ContextualPopover),
        'the date picker',
      );
      // The row and the header that the clipped popover used to lose off the
      // top: present is not enough, they have to be on screen.
      expectInsideWindow(tester, find.text('Today'), 'the quick-pick row');
      // Narrowed to fit, the quick-pick row wraps onto a second line, which
      // costs the calendar the month's last week unless the picker takes the
      // window's height back. The clip is inside the popover's own bounds, so
      // it shows up as the height given rather than as an overflow.
      final picker = tester.getRect(find.byType(ContextualPopover));
      expect(
        picker.height,
        greaterThan(kReminderFloaterSize.height - 40),
        reason: 'the narrowed picker needs the height back for its last week',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    "the daily time picker opens whole inside the floater's window",
    (tester) async {
      await pumpFloater(tester);

      // Daily is the default, so the clock pill opens the time wheel.
      await tester.tap(find.byIcon(PhosphorIconsRegular.clock));
      await tester.pumpAndSettle();

      expectInsideWindow(
        tester,
        find.byType(ContextualPopover),
        'the time picker',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

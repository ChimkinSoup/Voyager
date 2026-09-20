// The reminder floater's window is a fixed size the form cannot talk back to,
// so the size has to be the form's own: the editor at its default — a daily
// rule, this device registered, no validation line — with nothing left over,
// or it opens above a band of dead background. Measured in the real theme and
// faces, which is what the form is actually laid out in.
//
// The validation line under the form is the exception, and has its room
// reserved: it is one Create away in the ordinary course of things, and it
// would push the buttons out of a window sized without it. What the form grows
// by beyond that — more devices than fit a row — scrolls inside the window.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

import 'fakes/fake_weather_api_client.dart';
import 'narrow_window_harness.dart';

/// The form's bottom padding, below the Create button.
const _bottomPadding = 20.0;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the reminder floater fits the editor',
    (tester) async {
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
      // One registered device, the floor in a signed-in app: its pill stands in
      // for the "no devices yet" line, and a second one shares that row.
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

      double formHeight() =>
          tester.getRect(find.widgetWithText(GlassButton, 'Create')).bottom +
          _bottomPadding;

      // The default form is that one line short of the window, and no more: the
      // validation line's room is reserved, nothing else is.
      expect(formHeight(), lessThan(kReminderFloaterSize.height));
      expect(
        kReminderFloaterSize.height - formHeight(),
        lessThanOrEqualTo(24.0),
      );

      // Create with an empty title puts the validation line above the buttons:
      // the tallest the form goes on its own, and the window's own height.
      await tester.tap(find.widgetWithText(GlassButton, 'Create'));
      await tester.pump();
      expect(find.text('Give the reminder a title'), findsOneWidget);
      expect(formHeight(), kReminderFloaterSize.height);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

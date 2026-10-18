// The reminder floater's window is sized to the form: the editor at its
// default — a daily rule, this device registered, no validation line — with
// nothing left over, or it opens above a band of dead background. Measured in
// the real theme and faces, which is what the form is actually laid out in.
//
// The validation line under the form is not reserved: the form reports its
// height and the window grows by that. What the form grows by beyond that —
// more devices than fit a row — scrolls inside the window.

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
const _bottomPadding = 14.0;

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

      // The form's height, as the floater would be told it.
      var reportedHeight = 0.0;
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
                onHeight: (h) => reportedHeight = h,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      double formHeight() =>
          tester.getRect(find.widgetWithText(GlassButton, 'Create')).bottom +
          _bottomPadding;

      // The window opens at the default form's height, to the pixel, and
      // what the form reports is the whole of it.
      expect(formHeight(), lessThanOrEqualTo(kReminderFloaterSize.height));
      expect(kReminderFloaterSize.height - formHeight(), lessThan(1.0));
      expect(reportedHeight, closeTo(formHeight(), 0.01));
      final opened = reportedHeight;

      // Create with an empty title puts the validation line above the
      // buttons, and the reported height grows to take it in.
      await tester.tap(find.widgetWithText(GlassButton, 'Create'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Give the reminder a title'), findsOneWidget);
      expect(reportedHeight, greaterThan(opened));
      expect(reportedHeight, closeTo(formHeight(), 0.01));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

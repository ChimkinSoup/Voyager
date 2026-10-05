// The in-app reminder editor in a window too short for its form (BUG-036):
// the form scrolls, but the Title field's floating label is not clipped at
// the scroll view's top, and the On row stays on screen above the buttons.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

void main() {
  // 2000×1100 and the minimum window (1440×1040), both at 200 %.
  for (final size in const [Size(1000, 550), Size(720, 520)]) {
    testWidgets('at $size the Title label and the On row are whole', (
      tester,
    ) async {
      await loadRealFonts(tester);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceRegistrationsProvider.overrideWith(
              (ref) async => const <DeviceRegistration>[],
            ),
          ],
          child: MaterialApp(
            theme: VoyagerTheme.forMode(
              AppThemeMode.dark,
              accent: const Color(0xFF7C9EFF),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showScheduledReminderEditor(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final viewport = tester.getRect(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final title = tester.getRect(find.text('Title').first);
      expect(title.top, greaterThanOrEqualTo(viewport.top));

      final on = tester.getRect(find.byType(SwitchListTile));
      final create = tester.getRect(find.text('Create'));
      expect(on.top, greaterThanOrEqualTo(viewport.bottom));
      expect(on.bottom, lessThanOrEqualTo(create.top));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });
  }
}

// The reminder editor sets the time and, for a weekly rule, its days on one
// row. This is the check that the row holds all seven day pills beside the
// time pill in the 460pt dialog without overflowing, and that the headings
// those controls used to carry ("Time", "When", "Days") are gone.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

Future<void> _openEditor(WidgetTester tester) async {
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
}

void main() {
  testWidgets('weekly time and day pills share one row', (tester) async {
    await loadRealFonts(tester);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openEditor(tester);
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // Every day pill sits on the time pill's line, to its right.
    final time = tester.getRect(find.byIcon(PhosphorIconsRegular.clock));
    for (final day in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) {
      final pill = tester.getRect(find.text(day));
      expect(pill.center.dy, closeTo(time.center.dy, 2), reason: '$day row');
      expect(pill.left, greaterThan(time.right), reason: '$day is right of it');
    }

    // No headings above the controls any more.
    expect(find.text('Time'), findsNothing);
    expect(find.text('When'), findsNothing);
    expect(find.text('Days'), findsNothing);
  });

  testWidgets('a one-time reminder shows only the date-and-time pill', (
    tester,
  ) async {
    await loadRealFonts(tester);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openEditor(tester);
    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Mon'), findsNothing);
    expect(find.text('When'), findsNothing);
  });
}

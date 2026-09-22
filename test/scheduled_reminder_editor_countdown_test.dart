// The reminder editor says how long it is until the reminder goes off, the
// same countdown the Inbox row carries. This is the check that the line is
// there for a new reminder, and gone when there is nothing to count down to.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

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
  testWidgets('a new reminder counts down to its first firing', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openEditor(tester);
    // A new reminder starts on the next whole hour, so it is always under an
    // hour away.
    expect(find.textContaining('Fires in'), findsOneWidget);

    // A weekly rule with no day picked has nothing to count down to.
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fires in'), findsOneWidget);
    // 2024-01-01 was a Monday, so day N of that week is weekday N.
    final today = DateFormat.E().format(
      DateTime(2024, 1, DateTime.now().weekday),
    );
    await tester.tap(find.text(today));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fires in'), findsNothing);
  });

  testWidgets('a reminder switched off drops the countdown', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openEditor(tester);
    expect(find.textContaining('Fires in'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fires in'), findsNothing);
  });
}

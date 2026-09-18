// The second click of a fast double-click behind an open popover must not
// close the surface the popover was opened from.
//
// A barrier is switched off with `IgnorePointer`, which is a build: for one
// frame after the popover pops, its barrier is still live, and the dismissal
// it answers with pops whatever is now on top — the dialog underneath.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
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
  for (final gap in const [
    Duration.zero,
    Duration(milliseconds: 16),
    Duration(milliseconds: 60),
    Duration(milliseconds: 120),
  ]) {
    testWidgets('double click ${gap.inMilliseconds}ms apart keeps the editor', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _openEditor(tester);
      await tester.tap(find.byIcon(PhosphorIconsRegular.clock));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget, reason: 'time popover open');

      // A point on the editor, well clear of the popover.
      final target = tester.getCenter(find.text('Weekly'));
      await tester.tapAt(target);
      if (gap > Duration.zero) await tester.pump(gap);
      await tester.tapAt(target);
      await tester.pumpAndSettle();

      expect(find.text('Done'), findsNothing, reason: 'popover closed');
      expect(find.text('New reminder'), findsOneWidget, reason: 'editor stays');
    });
  }

  testWidgets('the second click lands on the editor', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openEditor(tester);
    await tester.tap(find.byIcon(PhosphorIconsRegular.clock));
    await tester.pumpAndSettle();

    final target = tester.getCenter(find.text('Weekly'));
    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(target);
    await tester.pumpAndSettle();

    // Weekly was selected by the second click: its day pills are now shown.
    expect(find.text('Mon'), findsOneWidget);
  });

  // The same race is in every dismissible route, not just this popover.
  testWidgets('a dialog over a dialog does not take the lower one with it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.forMode(
          AppThemeMode.dark,
          accent: const Color(0xFF7C9EFF),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showVoyagerDialog<void>(
                  context: context,
                  builder: (lower) => AlertDialog(
                    title: const Text('lower'),
                    content: SizedBox(
                      width: 400,
                      height: 300,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: TextButton(
                          onPressed: () => showVoyagerDialog<void>(
                            context: lower,
                            builder: (_) =>
                                const AlertDialog(title: Text('upper')),
                          ),
                          child: const Text('go deeper'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('go deeper'));
    await tester.pumpAndSettle();
    expect(find.text('upper'), findsOneWidget);

    // The lower dialog's title, well clear of the upper dialog.
    final target = tester.getCenter(find.text('lower'));
    await tester.tapAt(target);
    await tester.tapAt(target);
    await tester.pumpAndSettle();

    expect(find.text('upper'), findsNothing);
    expect(find.text('lower'), findsOneWidget);
  });
}

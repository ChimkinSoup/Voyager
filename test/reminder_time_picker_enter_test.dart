// Enter, or Ctrl+Enter, in a reminder's time picker applies the time and
// closes the picker in one press — without saving the reminder underneath.
// The one-time picker used to only move focus off its time field, so the
// first press seemed to do nothing. Text that is not a time yet keeps the
// picker open rather than saving whatever the last readable keystroke left.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

Future<void> _openEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
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
}

/// Enter as the desktop embedder delivers it: the key event first, and only
/// if nothing claims it does a focused text field perform its action.
Future<void> _pressEnter(WidgetTester tester, {required bool ctrl}) async {
  if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
  final editing = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  if (!handled && editing != null) {
    await tester.testTextInput.receiveAction(TextInputAction.done);
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
  if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  for (final daily in [false, true]) {
    for (final ctrl in [false, true]) {
      testWidgets(
        '${ctrl ? 'Ctrl+Enter' : 'Enter'} in the ${daily ? 'daily' : 'one-time'}'
        ' time picker applies the time and closes only the picker',
        (tester) async {
          await _openEditor(tester);
          if (daily) {
            await tester.tap(find.text('Daily'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byIcon(PhosphorIconsRegular.clock));
          await tester.pumpAndSettle();

          await tester.enterText(
            find.descendant(
              of: find.byType(
                daily ? TimeSelectorPopover : DateTimeSelectorPopover,
              ),
              matching: find.byType(EditableText),
            ),
            '3:15 PM',
          );
          await tester.pump();
          await _pressEnter(tester, ctrl: ctrl);

          expect(find.byType(DateTimeSelectorPopover), findsNothing);
          expect(find.byType(TimeSelectorPopover), findsNothing);
          expect(find.textContaining('3:15'), findsOneWidget);
          // The editor is still open and was not submitted (a submit with no
          // title would say so).
          expect(find.text('New reminder'), findsOneWidget);
          expect(find.text('Give the reminder a title'), findsNothing);
        },
      );
    }
  }

  for (final daily in [false, true]) {
    testWidgets(
      'an unreadable time keeps the ${daily ? 'daily' : 'one-time'} picker '
      'open, showing the time it would save',
      (tester) async {
        await _openEditor(tester);
        if (daily) {
          await tester.tap(find.text('Daily'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byIcon(PhosphorIconsRegular.clock));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(
            daily ? TimeSelectorPopover : DateTimeSelectorPopover,
          ),
          matching: find.byType(EditableText),
        );
        // "2" reads as 2:00; "25" is no hour at all.
        await tester.enterText(field, '2');
        await tester.pump();
        await tester.enterText(field, '25');
        await tester.pump();
        await _pressEnter(tester, ctrl: false);

        expect(
          find.byType(daily ? TimeSelectorPopover : DateTimeSelectorPopover),
          findsOneWidget,
        );
        expect(
          tester.widget<EditableText>(field).controller.text,
          contains('2:00'),
        );
        expect(find.text('Give the reminder a title'), findsNothing);
      },
    );
  }

  testWidgets('Enter on a cleared optional time returns the date alone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DateTime? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  picked = await showContextualPopover<DateTime>(
                    context: context,
                    buttonContext: context,
                    width: 500,
                    height: 380,
                    builder: (_) => DateTimeSelectorPopover(
                      initialDateTime: DateTime(2026, 10, 5, 9, 30),
                      optionalTime: true,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(DateTimeSelectorPopover),
        matching: find.byType(EditableText),
      ),
      '',
    );
    await tester.pump();
    await _pressEnter(tester, ctrl: false);

    expect(find.byType(DateTimeSelectorPopover), findsNothing);
    expect(picked, DateTime(2026, 10, 5));
  });
}

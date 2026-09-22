import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/top_chrome_inset.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/enums.dart';

/// Pumps a bare app and hands back a context inside its overlay.
Future<BuildContext> pumpHost(WidgetTester tester, {ThemeData? theme}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          ctx = context;
          return const Scaffold();
        },
      ),
    ),
  );
  return ctx;
}

void main() {
  testWidgets('a working toast becomes its own result in the same card', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);

    final toast = showVoyagerToast(ctx, message: 'Adding image…');
    await tester.pump();

    // No icon means the toast is still working, which is the whole point of
    // raising it before the work rather than after.
    expect(find.text('Adding image…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    toast.update(
      message: 'Image added',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(milliseconds: 1600),
    );
    await tester.pump();

    expect(find.text('Adding image…'), findsNothing);
    expect(find.text('Image added'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // One card throughout: the result replaced the spinner in place rather
    // than sliding in over a copy of it on its way out, which is what the
    // single tick and the absent spinner together say.
    expect(find.byIcon(PhosphorIconsRegular.check), findsOneWidget);

    // The dwell only starts at the update — before it there was nothing to
    // count down, so a slow ingest can never time its own spinner out.
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pumpAndSettle();
    expect(find.text('Image added'), findsNothing);
  });

  testWidgets('a toast with no dwell stays up until it is dismissed', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);

    final toast = showVoyagerToast(ctx, message: 'Adding image…');
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Adding image…'), findsOneWidget);

    toast.dismiss();
    await tester.pumpAndSettle();
    expect(find.text('Adding image…'), findsNothing);
  });

  testWidgets('a result arriving after a dismiss does not raise the toast', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);

    final toast = showVoyagerToast(ctx, message: 'Adding image…');
    await tester.pump();
    toast.dismiss();
    await tester.pumpAndSettle();

    // What an ingest that finished after the user waved the spinner away
    // would do. It must not put the card back — and must not touch an overlay
    // entry that has already been removed.
    toast.update(message: 'Image added', icon: PhosphorIconsRegular.check);
    await tester.pumpAndSettle();

    expect(find.text('Image added'), findsNothing);
  });

  testWidgets('a toast on its way out no longer answers its own button', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    var pressed = 0;

    final toast = showVoyagerToast(
      ctx,
      message: 'Deleted first',
      icon: PhosphorIconsRegular.trash,
      actions: [VoyagerToastAction(label: 'Undo', onPressed: () => pressed++)],
    );
    // Settled first: a reverse started from a controller still at zero
    // finishes in the same frame, which is not the window under test.
    await tester.pumpAndSettle();

    // Replacement is not atomic: `dismiss()` starts a 180 ms reverse and the
    // entry stays in the overlay for all of it, still hit-testing at opacity
    // zero. A click on the invisible button used to run its action.
    toast.dismiss();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(pressed, 0);
  });

  testWidgets('a hovered toast holds its dwell, but not forever', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    showVoyagerToast(
      ctx,
      message: 'Deleted task',
      icon: PhosphorIconsRegular.trash,
      dwell: const Duration(seconds: 8),
      // Actions are what make the card interactive, and only an interactive
      // card carries the MouseRegion that holds the clock.
      actions: [VoyagerToastAction(label: 'Undo', onPressed: () {})],
    );
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Deleted task'))),
    );
    await tester.pump();

    // Well past the dwell, and still up: the offer is being read.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Deleted task'), findsOneWidget);

    // The hold used to be indefinite, which depends on an `onExit` that a
    // minimized window never delivers. It is capped instead.
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.text('Deleted task'), findsNothing);
  });

  testWidgets('two toasts sit under each other rather than on top', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);

    showVoyagerToast(
      ctx,
      message: 'Deleted "Push day"',
      icon: PhosphorIconsRegular.trash,
      dwell: const Duration(seconds: 8),
      actions: [VoyagerToastAction(label: 'Undo', onPressed: () {})],
    );
    showVoyagerToast(
      ctx,
      message: 'Copied `git diff`',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(milliseconds: 1400),
    );
    await tester.pumpAndSettle();

    // Both legible, and the newer one below the offer it arrived over rather
    // than across it.
    final offer = tester.getRect(find.text('Deleted "Push day"'));
    final copy = tester.getRect(find.text('Copied `git diff`'));
    expect(copy.top, greaterThanOrEqualTo(offer.bottom));

    // The copy takes itself away on its own clock; the longer offer stays,
    // and closes the gap the copy leaves behind it.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.text('Copied `git diff`'), findsNothing);
    expect(find.text('Deleted "Push day"'), findsOneWidget);
    expect(tester.getRect(find.text('Deleted "Push day"')), offer);
  });

  testWidgets('a repeat of what is already up counts up in place', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);

    for (var i = 0; i < 3; i++) {
      showVoyagerToast(
        ctx,
        message: 'Copied `git diff`',
        icon: PhosphorIconsRegular.check,
        dwell: const Duration(milliseconds: 1400),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    // One card, not three — and it says how many times it happened.
    expect(find.text('Copied `git diff`'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);

    // Each repeat restarts the dwell, so the count is still up a full dwell
    // after the *first* copy would have taken it away.
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('Copied `git diff`'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Copied `git diff`'), findsNothing);
  });

  testWidgets('work in flight never joins another toast', (tester) async {
    final ctx = await pumpHost(tester);

    final first = showVoyagerToast(ctx, message: 'Adding image…');
    final second = showVoyagerToast(ctx, message: 'Adding image…');
    // Pumped rather than settled: a spinner never stops turning.
    await tester.pump(const Duration(milliseconds: 200));

    // Two uploads are two pieces of work, each with its own result to report,
    // so they get a card each however alike the wording is.
    expect(first, isNot(same(second)));
    expect(find.text('Adding image…'), findsNWidgets(2));

    first.update(message: 'Image added', icon: PhosphorIconsRegular.check);
    await tester.pump();
    expect(find.text('Image added'), findsOneWidget);
    expect(find.text('Adding image…'), findsOneWidget);
  });

  testWidgets('the stack starts below whatever is holding the top', (
    tester,
  ) async {
    addTearDown(() => topChromeInset.value = 0);
    final ctx = await pumpHost(tester);

    showVoyagerToast(
      ctx,
      message: 'Copied `git diff`',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(milliseconds: 1400),
    );
    await tester.pumpAndSettle();
    final clear = tester.getRect(find.text('Copied `git diff`'));

    // What the live workout's island publishes while it is pinned to the top.
    // The toast is drawn in the root overlay, a sibling of the shell, so this
    // notifier is the only thing that can tell it the spot is taken.
    topChromeInset.value = 64;
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Copied `git diff`')).top, clear.top + 64);

    // And it comes back up when the workout ends under it, rather than staying
    // parked over an island that is no longer there.
    topChromeInset.value = 0;
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Copied `git diff`')), clear);
  });

  testWidgets('a toast is pressable from the frame it appears', (tester) async {
    final ctx = await pumpHost(tester);
    var pressed = 0;

    showVoyagerToast(
      ctx,
      message: 'Hidden "A"',
      icon: PhosphorIconsRegular.eyeSlash,
      dwell: const Duration(seconds: 8),
      actions: [VoyagerToastAction(label: 'Undo', onPressed: () => pressed++)],
    );
    // One frame — the entry animation has barely started. The card is faded
    // and still sliding down, but it is full height and its button is real:
    // collapsing it on the way in would leave Undo unhittable until the
    // animation finished.
    await tester.pump();

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(pressed, 1);
  });

  testWidgets('a dismissed toast completes its done future', (tester) async {
    final ctx = await pumpHost(tester);
    var done = false;

    final toast = showVoyagerToast(ctx, message: 'Working…');
    await tester.pump();
    unawaited(toast.done.then((_) => done = true));
    await tester.pump();
    expect(done, isFalse);

    toast.dismiss();
    await tester.pumpAndSettle();
    // What lets the soft-delete layer drop the snapshot its standing offer
    // holds, instead of retaining it for the life of the app.
    expect(done, isTrue);
  });

  // The action buttons are painted in the accent, and the accent is whatever
  // the user picked. A pale one used to be the label color as well as the
  // fill, which left the words invisible on the button they sat in.
  for (final mode in AppThemeMode.values) {
    testWidgets('a toast action stays legible on a pale accent in $mode', (
      tester,
    ) async {
      const pale = Color(0xFFF3E6A8);
      final theme = VoyagerTheme.forMode(mode, accent: pale);
      final ctx = await pumpHost(tester, theme: theme);

      showVoyagerToast(
        ctx,
        message: 'Your last session left scratch code behind.',
        icon: PhosphorIconsRegular.clockCounterClockwise,
        actions: [
          VoyagerToastAction(label: 'Restore', onPressed: () {}),
          VoyagerToastAction(label: 'Discard', onPressed: () {}),
        ],
      );
      await tester.pumpAndSettle();

      // What the label is actually painted on: the accent wafer (light) or
      // the near-solid accent plate (dark), over the toast card.
      final scheme = theme.colorScheme;
      final fill = Color.alphaBlend(
        scheme.primary.withValues(
          alpha: GlassButton.defaultGlassOpacity(mode == AppThemeMode.dark),
        ),
        scheme.surfaceContainerHighest,
      );

      for (final label in ['Restore', 'Discard']) {
        final color = tester.widget<Text>(find.text(label)).style?.color;
        expect(color, isNotNull, reason: '$label carries an explicit color');
        expect(
          contrast(color!, fill),
          greaterThanOrEqualTo(4.5),
          reason: '$label reads against the button it sits in',
        );
      }
    });
  }
}

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

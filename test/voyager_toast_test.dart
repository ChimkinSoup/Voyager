import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';

/// Pumps a bare app and hands back a context inside its overlay.
Future<BuildContext> pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
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
}

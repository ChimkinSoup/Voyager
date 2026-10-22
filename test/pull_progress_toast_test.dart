// The startup pull's progress toast: silent on a quick launch, counting on a
// slow one (a restore onto an empty device, or the weekly full pull), and a
// tick when it lands.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/sync/pull_progress_toast.dart';

Future<BuildContext> _pumpHost(WidgetTester tester) async {
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
  testWidgets('a pull that lands before the delay never shows', (tester) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: true,
    );

    toast.report(40, 40);
    toast.complete();
    await tester.pump(const Duration(seconds: 5));

    expect(find.textContaining('Restor'), findsNothing);
  });

  testWidgets('a slow pull counts up, then ticks', (tester) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: true,
    );

    toast.report(0, 0);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Restoring from the cloud…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    toast.report(1204, 2880);
    await tester.pump();
    expect(
      find.text('Restoring from the cloud · 1,204 of 2,880 items'),
      findsOneWidget,
    );

    toast.report(2880, 2880);
    toast.complete();
    await tester.pump();
    expect(find.text('Restored 2,880 items'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsRegular.check), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.text('Restored 2,880 items'), findsNothing);
  });

  testWidgets('a slow pull on a device that has synced before says syncing', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: false,
    );

    toast.report(1204, 2880);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(
      find.text('Syncing with the cloud · 1,204 of 2,880 items'),
      findsOneWidget,
    );

    toast.report(2880, 2880);
    toast.complete();
    await tester.pump();
    expect(find.text('Synced 2,880 items'), findsOneWidget);
    expect(find.textContaining('Restor'), findsNothing);

    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('a slow catch-up with nothing to apply never shows', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: false,
    );

    toast.report(0, 0);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    // A weekly full pull that found every document unchanged.
    toast.report(40, 40);
    await tester.pump();
    toast.complete();
    await tester.pump(const Duration(seconds: 5));

    expect(find.textContaining('Sync'), findsNothing);
  });

  testWidgets('a slow catch-up shows once something is listed to apply', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: false,
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.textContaining('Sync'), findsNothing);

    toast.report(0, 7);
    await tester.pump();
    expect(find.text('Syncing with the cloud · 0 of 7 items'), findsOneWidget);

    toast.report(7, 7);
    toast.complete();
    await tester.pump();
    expect(find.text('Synced 7 items'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('a report after the pull has finished raises nothing', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: false,
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    toast.cancel();
    toast.report(0, 7);
    await tester.pump();

    expect(find.textContaining('Sync'), findsNothing);
  });

  testWidgets('a failed pull takes the toast away', (tester) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(
      () => Overlay.of(ctx, rootOverlay: true),
      restoring: true,
    );

    toast.report(10, 2880);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.textContaining('10 of 2,880'), findsOneWidget);

    toast.cancel();
    await tester.pumpAndSettle();
    expect(find.textContaining('Restor'), findsNothing);
  });
}

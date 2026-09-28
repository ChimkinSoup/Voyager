// The startup pull's progress toast: silent on a quick launch, counting on a
// slow one (a restore onto an empty device), and a tick when it lands.

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
    final toast = PullProgressToast(() => Overlay.of(ctx, rootOverlay: true));

    toast.report(40, 40);
    toast.complete();
    await tester.pump(const Duration(seconds: 5));

    expect(find.textContaining('Restor'), findsNothing);
  });

  testWidgets('a slow pull counts up, then ticks', (tester) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(() => Overlay.of(ctx, rootOverlay: true));

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

  testWidgets('a failed pull takes the toast away', (tester) async {
    final ctx = await _pumpHost(tester);
    final toast = PullProgressToast(() => Overlay.of(ctx, rootOverlay: true));

    toast.report(10, 2880);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.textContaining('10 of 2,880'), findsOneWidget);

    toast.cancel();
    await tester.pumpAndSettle();
    expect(find.textContaining('Restor'), findsNothing);
  });
}

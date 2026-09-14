// The animated background pauses while a scrimmed modal is open, because a
// glass sheet re-blurs the moving background on every frame — see
// modal_scrim_observer.dart. Popovers and the zoom overlays have no scrim and
// must leave it running.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/motion/modal_scrim_observer.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

void main() {
  late BuildContext context;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ModalScrimObserver()],
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    // The home route is reported from inside build and published after it.
    await tester.pump();
    expect(modalScrimOpen.value, isFalse);
  }

  testWidgets('a sheet pauses the background until it is popped', (
    tester,
  ) async {
    await pumpApp(tester);
    showVoyagerSheet<void>(
      context: context,
      kind: VoyagerSheetKind.editor,
      builder: (_) => const SizedBox(height: 200),
    );
    await tester.pump();
    expect(modalScrimOpen.value, isTrue);

    Navigator.of(context, rootNavigator: true).pop();
    // Already resumed while the sheet is still sliding out.
    await tester.pump();
    expect(modalScrimOpen.value, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a dialog over a sheet keeps it paused until both close', (
    tester,
  ) async {
    await pumpApp(tester);
    showVoyagerSheet<void>(
      context: context,
      builder: (_) => const SizedBox(height: 200),
    );
    await tester.pump(const Duration(seconds: 1));
    showVoyagerDialog<void>(
      context: context,
      builder: (_) => const SizedBox(width: 100, height: 100),
    );
    await tester.pump(const Duration(seconds: 1));

    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop();
    await tester.pump(const Duration(seconds: 1));
    expect(modalScrimOpen.value, isTrue);

    navigator.pop();
    await tester.pump(const Duration(seconds: 1));
    expect(modalScrimOpen.value, isFalse);
  });

  testWidgets('an overlay without a scrim leaves the background running', (
    tester,
  ) async {
    await pumpApp(tester);
    // The shape of the LeetCode detail / activity zoom routes.
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, _, _) => const SizedBox(width: 100, height: 100),
      ),
    );
    await tester.pump();
    expect(modalScrimOpen.value, isFalse);

    Navigator.of(context, rootNavigator: true).pop();
    await tester.pump(const Duration(seconds: 1));
  });
}

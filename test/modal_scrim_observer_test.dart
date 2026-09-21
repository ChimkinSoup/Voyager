// The animated background pauses while a scrimmed modal is open, because a
// glass sheet re-blurs the moving background on every frame — see
// modal_scrim_observer.dart. Popovers and the zoom overlays have no scrim and
// must leave it running.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

  testWidgets('an ambient pulse stops requesting frames under a scrim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ModalScrimObserver()],
        home: Builder(
          builder: (c) {
            context = c;
            return const PauseUnderModalScrim(child: _Pulse());
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Running: a Ticker asks for a frame on every vsync.
    expect(SchedulerBinding.instance.transientCallbackCount, 1);

    showVoyagerSheet<void>(
      context: context,
      builder: (_) => const SizedBox(height: 200),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(modalScrimOpen.value, isTrue);

    // Muted, so the sheet's window-sized BackdropFilter is not re-blurred
    // 120 times a second for as long as it sits open.
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
    var frames = 0;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (SchedulerBinding.instance.hasScheduledFrame) frames++;
    }
    expect(frames, 0);

    // ...and runs again once the sheet is gone.
    Navigator.of(context, rootNavigator: true).pop();
    await tester.pump(const Duration(seconds: 1));
    expect(modalScrimOpen.value, isFalse);
    await tester.pump(const Duration(milliseconds: 16));
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);
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

/// Stands in for the notification bell's badge and the workout island's live
/// dot: ambient decoration on an endless repeat.
class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 625),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (_, _) =>
        Opacity(opacity: _controller.value, child: const Icon(Icons.circle)),
  );
}

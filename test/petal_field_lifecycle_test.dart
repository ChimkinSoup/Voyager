import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/petal_field.dart';

/// Drives the platform lifecycle channel, which is what an
/// [AppLifecycleListener] — and so `WindowVisibility` — actually listens to.
Future<void> setLifecycleState(
  WidgetTester tester,
  AppLifecycleState state,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage(state.toString()),
    (_) {},
  );
  await tester.pump();
}

void main() {
  // Never pumpAndSettle in here: the petal field animates forever by design.
  const boundaryKey = Key('petal-field-boundary');

  Widget field() => const Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: boundaryKey,
        child: SizedBox(width: 300, height: 300, child: PetalField()),
      ),
    ),
  );

  /// The field's actual pixels. Whether they change between two of these is
  /// the only honest test of "is it still animating" — every cheaper proxy
  /// (`hasScheduledFrame`, `debugNeedsPaint`) is cleared by the pump that
  /// would have to observe it.
  Future<Uint8List> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    // runAsync, not a bare await: toImage completes off the fake clock the
    // test binding runs on, so awaiting it directly deadlocks the test.
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
  }

  /// Runs the field for [ms] of its own 16ms ticks.
  Future<void> run(WidgetTester tester, int ms) async {
    for (var elapsed = 0; elapsed < ms; elapsed += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('freezes while the window is hidden and thaws when it returns', (
    tester,
  ) async {
    await tester.pumpWidget(field());
    // Long enough for petals to have spawned and faded in — a blank field
    // would make every comparison below vacuously equal.
    await run(tester, 1200);
    final moving = await pixels(tester);
    await run(tester, 200);
    expect(
      await pixels(tester),
      isNot(moving),
      reason: 'the field should be animating with the window up',
    );

    await setLifecycleState(tester, AppLifecycleState.hidden);
    final frozen = await pixels(tester);
    await run(tester, 500);
    expect(
      await pixels(tester),
      frozen,
      reason: 'a minimised window must not keep the animation running',
    );

    await setLifecycleState(tester, AppLifecycleState.resumed);
    await run(tester, 200);
    expect(await pixels(tester), isNot(frozen));
  });

  testWidgets('keeps animating when the window merely loses focus', (
    tester,
  ) async {
    await tester.pumpWidget(field());
    await run(tester, 1200);
    await setLifecycleState(tester, AppLifecycleState.inactive);
    final before = await pixels(tester);
    await run(tester, 200);
    expect(await pixels(tester), isNot(before));
  });

  testWidgets('advances by repainting, without rebuilding the field', (
    tester,
  ) async {
    await tester.pumpWidget(field());
    final first = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(PetalField),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter;
    await run(tester, 100);
    final now = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(PetalField),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter;
    expect(
      identical(now, first),
      isTrue,
      reason: 'a new painter each frame means the whole field rebuilt',
    );
  });
}

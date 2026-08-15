// A `BackdropFilter` can only sample inside its enclosing saveLayer, and any
// ancestor opacity strictly between 0 and 1 creates one. So a page transition
// that fades in the arriving view leaves every glass surface on it frosting an
// empty backdrop for the length of the animation — bright enough to read as a
// stuck hover highlight — then snapping to its true appearance the moment the
// animation ends.
//
// The first test measures the hazard in pixels, because that is the only thing
// that proves it is real. The rest assert the invariant that routes around it:
// nothing between arriving glass and the screen may hold a fractional opacity
// while a transition runs. That is checked structurally rather than in pixels
// — during a dissolve the departing view genuinely covers the arriving one, so
// composited pixels are expected to differ and cannot tell us anything.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_page.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

class _FakeLeetCodeRepository implements LeetCodeRepository {
  _FakeLeetCodeRepository(this.problems);

  final List<LeetCodeProblem> problems;

  @override
  Future<List<LeetCodeProblem>> listProblems({bool includeDeleted = false}) async =>
      problems;

  @override
  Future<LeetCodeProblem?> getProblem(String id) async =>
      problems.where((p) => p.id == id).firstOrNull;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

final _now = DateTime.utc(2026, 8, 9, 12);
final _boundaryKey = GlobalKey();

/// Every ancestor of [finder] currently holding an opacity that forces a
/// saveLayer, and a saveLayer is exactly what cuts a descendant
/// `BackdropFilter` off from the real backdrop.
///
/// Read from the opacity values rather than from `debugLayer`, which keeps
/// whatever layer the last paint produced and so reports staleness as a fault.
/// The alpha is rounded the way `Opacity` and `FadeTransition` round it, and
/// both skip the layer entirely at a full 0 or 255 — so an empty result means
/// the glass below is compositing against the true screen.
List<String> _fadingAncestors(WidgetTester tester, Finder finder) {
  final found = <String>[];
  RenderObject? node = tester.renderObject(finder);
  while (node != null) {
    final double? opacity = switch (node) {
      RenderOpacity(:final opacity) => opacity,
      RenderAnimatedOpacity(:final opacity) => opacity.value,
      _ => null,
    };
    if (opacity != null) {
      final alpha = (opacity.clamp(0.0, 1.0) * 255).round();
      if (alpha != 0 && alpha != 255) {
        found.add('${node.runtimeType} at ${opacity.toStringAsFixed(3)}');
      }
    }
    node = node.parent;
  }
  return found;
}

Finder _glassButton(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(GlassButton),
);

/// Stand-in for the shader the app paints behind everything. Deliberately not
/// a flat fill: a flat backdrop blurs to itself, which would hide the very
/// difference under test.
Widget _background({required Widget child}) => Stack(
  fit: StackFit.expand,
  children: [
    const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101828), Color(0xFF2B1B3D)],
        ),
      ),
    ),
    for (var i = 0; i < 18; i++)
      Positioned(
        left: (i * 71).toDouble() % 900,
        top: (i * 47).toDouble() % 220,
        child: Container(
          width: 30,
          height: 30,
          color: const Color(0xFF7C9EFF),
        ),
      ),
    child,
  ],
);

void main() {
  testWidgets('an opacity layer measurably changes how glass renders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<double> meanBlue(double opacity) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: VoyagerTheme.dark(),
          home: RepaintBoundary(
            key: _boundaryKey,
            child: _background(
              child: Positioned(
                left: 60,
                top: 60,
                width: 200,
                height: 44,
                child: Opacity(
                  opacity: opacity,
                  child: GlassButton(
                    onPressed: () {},
                    icon: const Icon(Icons.play_circle),
                    label: 'Study',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final boundary =
          _boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      var mean = 0.0;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.0);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final bytes = data!.buffer.asUint8List();
        var b = 0, n = 0;
        for (var y = 60; y < 104; y++) {
          for (var x = 60; x < 260; x++) {
            b += bytes[(y * image.width + x) * 4 + 2];
            n++;
          }
        }
        mean = b / n;
        image.dispose();
      });
      return mean;
    }

    // 1.0 skips the opacity layer; 0.996 rounds to alpha 254 and forces one
    // while being visually indistinguishable. Any difference between the two
    // is the confined backdrop and nothing else.
    final noLayer = await meanBlue(1.0);
    final withLayer = await meanBlue(0.996);

    expect(
      (noLayer - withLayer).abs(),
      greaterThan(5),
      reason:
          'If this stops holding, Flutter has changed how BackdropFilter '
          'resolves its backdrop, and the transitions below no longer need to '
          'route around it.',
    );
  });

  testWidgets('leetcode: arriving deck never sits in an opacity layer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          leetCodeRepositoryProvider.overrideWithValue(
            _FakeLeetCodeRepository([
              for (var i = 1; i <= 6; i++)
                LeetCodeProblem(
                  id: '$i',
                  createdAt: _now,
                  updatedAt: _now,
                  title: 'Problem $i',
                  questionFrontendId: '$i',
                  difficulty: LeetCodeDifficulty.easy,
                  tags: const ['hash-table'],
                  solutions: const [LeetCodeSolution(algorithm: 'Hash map')],
                  solvedAt: _now,
                ),
            ]),
          ),
          remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        ],
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: RepaintBoundary(
            key: _boundaryKey,
            child: _background(child: const LeetCodePage()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Review Deck'));
    await tester.pump();

    // Across the whole 260ms transition, not just at the ends.
    for (var elapsed = 0; elapsed < 260; elapsed += 20) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        _fadingAncestors(tester, _glassButton('Study')),
        isEmpty,
        reason:
            'At ${elapsed + 20}ms into the transition the Study button was '
            'inside an opacity layer, so its BackdropFilter was frosting an '
            'empty backdrop instead of the app background.',
      );
    }
    await tester.pumpAndSettle();
  });

  testWidgets('shell: arriving branch never sits in an opacity layer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget branch(String label) => Center(
      child: SizedBox(
        width: 160,
        height: 44,
        child: GlassButton(
          onPressed: () {},
          icon: const Icon(Icons.play_circle),
          label: label,
        ),
      ),
    );

    Future<void> pumpAt(int index) => tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: RepaintBoundary(
          key: _boundaryKey,
          child: _background(
            child: ShellBranchContainer(
              currentIndex: index,
              children: [branch('Study'), branch('Cram')],
            ),
          ),
        ),
      ),
    );

    // Both directions. In index order the departing branch is above the
    // arriving one going one way and below it the other, so a single direction
    // would not exercise the reordering at all.
    for (final (from, to) in [(0, 1), (1, 0)]) {
      final arriving = to == 0 ? 'Study' : 'Cram';
      await pumpAt(from);
      await tester.pumpAndSettle();

      await pumpAt(to);
      await tester.pump();
      for (var elapsed = 0; elapsed < 180; elapsed += 30) {
        await tester.pump(const Duration(milliseconds: 30));
        expect(
          _fadingAncestors(tester, _glassButton(arriving)),
          isEmpty,
          reason:
              'Switching branch $from -> $to put the arriving branch in an '
              'opacity layer ${elapsed + 30}ms in. It must land on a flat 1.0 '
              'with the departing branch dissolving above it.',
        );
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets('MaterializeTransition is opaque before it finishes moving', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: _background(
          child: Center(
            child: MaterializeTransition(
              t: controller,
              child: const GlassSurface(
                child: SizedBox(width: 160, height: 80),
              ),
            ),
          ),
        ),
      ),
    );
    // MaterialApp brings its first route in on a fade of its own; let that
    // finish so the only opacity left in the tree is the one under test.
    await tester.pumpAndSettle();

    // Early on the surface is still arriving from nothing, so it is inside an
    // opacity layer — unavoidable, and invisible because there is no settled
    // appearance yet to compare it against.
    controller.value = 0.2;
    await tester.pump();
    expect(
      _fadingAncestors(tester, find.byType(GlassSurface)),
      isNotEmpty,
    );

    // By the time it is merely finishing its scale it must be fully opaque, so
    // the layer drops while the surface is still visibly moving rather than
    // landing as a snap on a popover that has already settled.
    for (final v in [0.5, 0.7, 0.9, 1.0]) {
      controller.value = v;
      await tester.pump();
      expect(
        _fadingAncestors(tester, find.byType(GlassSurface)),
        isEmpty,
        reason:
            'At t=$v the surface was still translucent, so its glass will '
            'snap when the opacity layer finally drops.',
      );
    }
  });
}

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// Gaia's field edge (the debug menu's Aurora edge v6) round [child]: dim at
/// rest and a little brighter under the cursor; while [focusNode] has focus,
/// soft lights in hues around the accent drift along it, with a faint glow
/// and shimmer.
class GaiaAuroraEdge extends StatefulWidget {
  const GaiaAuroraEdge({
    super.key,
    required this.focusNode,
    required this.child,
    this.radius = GaiaRadius.row,
    this.scale = 1,
    this.outset = EdgeInsets.zero,
  });

  final FocusNode focusNode;
  final Widget child;

  /// The edge's corners, as [child]'s own.
  final double radius;

  /// How wide its glow spreads, 1 for a full-size field; less for a small
  /// one, such as a one-line rename.
  final double scale;

  /// How far past [child] the edge runs, for a child with no room of its
  /// own round its text. Painted only: [child]'s size is unchanged.
  final EdgeInsets outset;

  /// Off in tests: the aurora runs for as long as a field has focus, which
  /// `pumpAndSettle` would wait on forever. It still shows, standing still.
  @visibleForTesting
  static var animate = true;

  @override
  State<GaiaAuroraEdge> createState() => _GaiaAuroraEdgeState();
}

class _GaiaAuroraEdgeState extends State<GaiaAuroraEdge>
    with SingleTickerProviderStateMixin {
  var _hovered = false;

  /// The aurora's two minutes, which its lights loop over, run while the
  /// field has focus.
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(minutes: 2),
  );

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    _syncSpin();
  }

  @override
  void didUpdateWidget(GaiaAuroraEdge old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
      _syncSpin();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    _spin.dispose();
    super.dispose();
  }

  void _onFocus() {
    _syncSpin();
    setState(() {});
  }

  void _syncSpin() => widget.focusNode.hasFocus && GaiaAuroraEdge.animate
      ? _spin.repeat()
      : _spin.stop();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // So the aurora's frames repaint the field alone, not what's painted
      // round it, as the composer's halo.
      child: RepaintBoundary(
        // Eased between rest (0) and focus (1).
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.focusNode.hasFocus ? 1 : 0),
          duration: GaiaMotion.move,
          curve: GaiaMotion.curve,
          builder: (context, t, child) => AnimatedBuilder(
            animation: _spin,
            builder: (context, child) => CustomPaint(
              foregroundPainter: _Aurora(
                t: t,
                time: _spin.value,
                rest: Colors.white.withValues(alpha: _hovered ? 0.18 : 0.1),
                accent: accent,
                radius: widget.radius,
                scale: widget.scale,
                outset: widget.outset,
              ),
              child: child,
            ),
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A rounded edge in [rest] that, as [t] runs to 1, takes on soft lights in
/// hues around [accent] which drift, swell and fade along it, over a faint
/// wash of the same hues turning all the way round, with a soft glow and
/// brighter streaks drifting along it. [time] runs 0 to 1 over the loop, and
/// everything comes back to where it began. Each light keeps to its own
/// stretch of the edge and drifts its colour on its own, so they never pile
/// up or turn one shade together.
class _Aurora extends CustomPainter {
  _Aurora({
    required this.t,
    required this.time,
    required this.rest,
    required this.accent,
    required this.radius,
    required this.scale,
    required this.outset,
  });

  final double t, time, radius, scale;
  final Color rest, accent;
  final EdgeInsets outset;

  /// Each light: its hue away from the accent, and how many times a loop it
  /// crosses, rises and swells, with a phase so they don't move as one.
  static const _lights = [
    (hue: 0.0, across: 2, rise: 3, phase: 0.0),
    (hue: 45.0, across: 3, rise: 2, phase: 2.1),
    (hue: -40.0, across: 1, rise: 4, phase: 4.2),
    (hue: 100.0, across: 4, rise: 1, phase: 1.3),
    (hue: 20.0, across: 3, rise: 5, phase: 3.4),
    (hue: -70.0, across: 2, rise: 3, phase: 5.5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      outset.inflateRect(Offset.zero & size).deflate(0.75),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rest,
    );
    if (t == 0) return;
    final base = HSLColor.fromColor(accent);
    final turn = time * 2 * math.pi;
    // A hue [shift] from the accent, drifting up to 25° either side of it and
    // back once a loop, out of step by [phase]; all of it kept to 60%, so no
    // further than 75° from the accent. At the accent's own lightness, kept
    // off the ends where no colour would show, and at full colour.
    Color hue(double shift, double phase) => base
        .withHue((base.hue + 0.6 * (shift + 25 * math.sin(turn + phase))) % 360)
        .withLightness(base.lightness.clamp(0.5, 0.82))
        .withSaturation(math.max(base.saturation, 0.9))
        .toColor();
    Shader wash(double alpha) => SweepGradient(
      colors: [
        // The last stop meets the first, so shares its phase.
        for (final (shift, phase) in [
          (0.0, 0.0),
          (45.0, 1.7),
          (-40.0, 3.4),
          (100.0, 5.1),
          (0.0, 0.0),
        ])
          hue(shift, phase).withValues(alpha: math.min(1, alpha * t)),
      ],
      transform: GradientRotation(turn),
    ).createShader(Offset.zero & size);
    canvas
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..shader = wash(0.45),
      )
      // The glow, spreading outward from the edge.
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6 * scale
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * scale)
          ..shader = wash(0.14 * 0.65),
      );
    // The shimmer: two sets of streaks of different widths drifting opposite
    // ways, so they never settle into a pattern. Each moves a whole number of
    // streaks a loop, to come back where it began.
    for (final (band, laps) in [(size.width / 7, 6), (size.width / 4, -4)]) {
      final shift = time * 2 * band * laps;
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(
            Offset(shift, 0),
            Offset(shift + band, 0),
            [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.1 * t),
            ],
            null,
            TileMode.mirror,
          ),
      );
    }
    // Each light's stretch of the edge.
    final slot = size.width / _lights.length;
    for (final (i, light) in _lights.indexed) {
      final p = light.phase;
      // A light wanders about the middle of its own stretch, on the top edge
      // or the bottom by turns, and reaches about as far as the next one's,
      // so neighbours meet but never all gather.
      final centre = Offset(
        slot * (i + 0.5) + 0.6 * slot * math.sin(light.across * turn + p),
        size.height * (i.isEven ? 0.15 : 0.85) +
            size.height * 0.3 * math.sin(light.rise * turn + 2 * p),
      );
      final reach =
          slot * (1.1 + 0.3 * math.sin((light.across + light.rise) * turn + p));
      // Brightness breathes a little too.
      final glow = 0.75 + 0.25 * math.sin((light.rise + 1) * turn + 3 * p);
      final colour = hue(light.hue, p);
      Shader shader(double alpha) => RadialGradient(
        colors: [
          colour.withValues(alpha: alpha * glow * t),
          colour.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: centre, radius: reach));
      // Layered, not added, so each keeps its own colour where they overlap.
      canvas
        ..drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..shader = shader(0.4),
        )
        // Blooming outward where it is, so the glow is brighter round it.
        ..drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8 * scale
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 * scale)
            ..shader = shader(0.14 * 0.765),
        );
    }
  }

  @override
  bool shouldRepaint(_Aurora old) =>
      old.t != t ||
      old.time != time ||
      old.rest != rest ||
      old.accent != accent ||
      old.radius != radius ||
      old.scale != scale ||
      old.outset != outset;
}

/// [GaiaAuroraEdge]'s painting, for an edge lit by something other than
/// focus, as the debug menu's shell studies light it on hover: [t] from rest
/// (0) to lit (1), [time] through its loop, 0 to 1.
CustomPainter gaiaAuroraPainter({
  required double t,
  required double time,
  required Color rest,
  required Color accent,
  required double radius,
  double scale = 1,
}) => _Aurora(
  t: t,
  time: time,
  rest: rest,
  accent: accent,
  radius: radius,
  scale: scale,
  outset: EdgeInsets.zero,
);

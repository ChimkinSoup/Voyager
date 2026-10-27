import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// A small Astral core for indeterminate work: two orbits and a point of light.
/// No particles, bloom choreography, or dependency on the chat orb's renderer.
class GaiaSpinner extends StatefulWidget {
  const GaiaSpinner({
    super.key,
    this.size = 24,
    this.color,
    this.label = 'Loading',
  }) : assert(size > 0 && size < double.infinity);

  final double size;

  /// The accent mixed into the Astral core's white light.
  final Color? color;
  final String label;

  @override
  State<GaiaSpinner> createState() => _GaiaSpinnerState();
}

class _GaiaSpinnerState extends State<GaiaSpinner>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate && !_turn.isAnimating) {
      _turn.repeat();
    } else if (!animate) {
      _turn.stop();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _SpinnerPainter(
            turn: _turn,
            color: widget.color ?? Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    ),
  );
}

/// How far behind each light (radians) the trail's gradient is sampled; dense
/// near the light, where its exponential fade is steepest.
const _trailStops = [
  0.0,
  0.1,
  0.25,
  0.45,
  0.7,
  1.0,
  1.4,
  2.0,
  3.0,
  math.pi * 2,
];

/// The trail's opacity, matching the old per-segment strokes, whose round caps
/// overlapped so each point of the orbit was covered about twice.
double _trailAlpha(double behind) =>
    1 - math.pow(0.75 - math.exp(-behind * 2.2) * 0.7, 1.85).toDouble();

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turn, required this.color})
    : super(repaint: turn);

  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Match the Astral material's accent-tinted light and warm gold orbit.
    final light = gaiaAstralLight(color);
    const gold = kGaiaAstralGold;
    final diameter = size.shortestSide;
    final radius = diameter * 0.42;
    final centre = size.center(Offset.zero);
    final phase = turn.value * math.pi * 2;
    final stroke = (diameter / 24).clamp(0.85, 2.0).toDouble();
    final minor = radius * 0.48;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    // Fixed intersecting planes keep the silhouette legible at 12 px; the
    // lights travel in opposite directions, rather than tumbling the whole orb.
    for (var orbit = 0; orbit < 2; orbit++) {
      final tint = orbit == 0 ? light : gold;
      final tilt = orbit == 0 ? -0.65 : 0.85;
      final head = (orbit == 0 ? phase : -phase) - math.pi / 2;
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(tilt);
      // One stroked oval with a sweep gradient for the fading trail: the
      // gradient is squashed like the orbit, so its angle is the orbit's own
      // parameter. Per-segment strokes cost ~5x more raster time.
      final cosH = math.cos(head), sinH = math.sin(head);
      final stops = orbit == 0 ? _trailStops.reversed : _trailStops;
      paint.shader = ui.Gradient.sweep(
        Offset.zero,
        [
          for (final behind in stops)
            tint.withValues(alpha: tint.a * _trailAlpha(behind)),
        ],
        [
          for (final behind in stops)
            orbit == 0 ? 1 - behind / (math.pi * 2) : behind / (math.pi * 2),
        ],
        TileMode.clamp,
        0,
        math.pi * 2,
        Float64List.fromList([
          ...[radius * cosH, minor * sinH, 0, 0],
          ...[-radius * sinH, minor * cosH, 0, 0],
          ...[0, 0, 1, 0],
          ...[0, 0, 0, 1],
        ]),
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: radius * 2,
          height: minor * 2,
        ),
        paint,
      );
      canvas.drawCircle(
        Offset(radius * cosH, minor * sinH),
        stroke * 0.8,
        Paint()..color = tint,
      );
      canvas.restore();
    }

    // A tiny, steady core survives reduced motion and reads on either theme.
    canvas.drawCircle(
      centre,
      diameter * 0.17,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                light.withValues(alpha: light.a * 0.3),
                light.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(center: centre, radius: diameter * 0.17),
            ),
    );
    canvas.drawCircle(centre, stroke * 1.1, Paint()..color = light);
  }

  @override
  bool shouldRepaint(_SpinnerPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.turn != turn;
}

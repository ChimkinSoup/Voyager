import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Immutable speck in a [SurfaceGrain] field. Coordinates are normalized to
/// the painted bounds (`x`/`y` ∈ [0, 1]) so the same field scales to any size.
@immutable
class SurfaceGrainParticle {
  const SurfaceGrainParticle({
    required this.x,
    required this.y,
    required this.size,
    required this.opacity,
    required this.lighter,
  });

  final double x;
  final double y;

  /// Edge length in logical pixels.
  final double size;

  /// Relative opacity before [SurfaceGrain.grainOpacity] is applied.
  final double opacity;

  /// When true, speck is a step lighter than the plate; otherwise darker.
  final bool lighter;
}

/// Deterministic particle field for [SurfaceGrainPainter].
///
/// Expensive work belongs here — not inside [CustomPainter.paint] on every
/// frame. Density is area-scaled and hard-capped so large sheets stay cheap.
class SurfaceGrainGenerator {
  SurfaceGrainGenerator._();

  /// Particles per 10,000 px² at [grainDensity] == 1.0.
  static const double _basePer10k = 180;

  /// Floor and ceiling on the area-scaled count. The floor only exists so a
  /// very small plate still shows *some* tooth; it is deliberately low,
  /// because anything near the per-area rate of a large sheet turns a button
  /// into the grainiest surface on screen (a 120x40 button asks for ~13).
  static const int minParticles = 12;
  static const int maxParticles = 2000;

  static List<SurfaceGrainParticle> generate({
    required int seed,
    required double area,
    required double grainDensity,
  }) {
    if (area <= 0 || grainDensity <= 0) {
      return const [];
    }

    final target = (_basePer10k * grainDensity * (area / 10000.0))
        .round()
        .clamp(minParticles, maxParticles);
    final random = math.Random(seed);
    final particles = List<SurfaceGrainParticle>.generate(target, (_) {
      final roll = random.nextDouble();
      final double size;
      final double opacityScale;
      if (roll < 0.85) {
        size = 1.0;
        opacityScale = 1.0;
      } else if (roll < 0.97) {
        size = 2.0;
        opacityScale = 0.7;
      } else {
        size = random.nextBool() ? 3.0 : 4.0;
        opacityScale = 0.45;
      }

      return SurfaceGrainParticle(
        x: random.nextDouble(),
        y: random.nextDouble(),
        size: size,
        opacity: opacityScale * (0.55 + random.nextDouble() * 0.45),
        lighter: random.nextBool(),
      );
    });

    return particles;
  }
}

/// Matte surface fill with subtle bidirectional luminance grain.
///
/// Intended for dark-theme control plates (buttons, cards). No assets, no
/// blur, no fragment shader — particles are generated once per size/config
/// and redrawn cheaply. Grain should be barely noticeable at arm's length.
class SurfaceGrain extends StatefulWidget {
  const SurfaceGrain({
    super.key,
    required this.color,
    this.child,
    this.borderRadius,
    this.grainOpacity = 0.025,
    this.grainDensity = 0.15,
    this.seed = 0,
  });

  /// Plate fill. Grain pulls a tiny step lighter and darker from this.
  final Color color;

  final Widget? child;

  /// When set, grain is clipped to the rounded rect (corners stay clean).
  final BorderRadius? borderRadius;

  /// Master strength. High-contrast / reduced-transparency callers should
  /// pass ~0.01 for a very faint residual tooth.
  final double grainOpacity;

  /// Relative particle density (area-scaled, then capped).
  final double grainDensity;

  /// Deterministic seed so repaints do not reshuffle the field.
  final int seed;

  @override
  State<SurfaceGrain> createState() => _SurfaceGrainState();
}

class _SurfaceGrainState extends State<SurfaceGrain> {
  List<SurfaceGrainParticle> _particles = const [];
  int? _cacheKey;

  /// Everything the *field* depends on. [SurfaceGrain.grainOpacity] and
  /// [SurfaceGrain.color] are deliberately absent: they are applied at paint
  /// time, so a contrast or hover change repaints the same specks instead of
  /// regenerating an identical field under the same seed.
  int _keyFor(Size size) {
    return Object.hash(
      widget.seed,
      widget.grainDensity,
      size.width.round(),
      size.height.round(),
    );
  }

  void _ensureParticles(Size size) {
    if (!size.isFinite || size.width <= 0 || size.height <= 0) return;
    final key = _keyFor(size);
    if (key == _cacheKey) return;
    _cacheKey = key;
    _particles = SurfaceGrainGenerator.generate(
      seed: widget.seed,
      area: size.width * size.height,
      grainDensity: widget.grainDensity,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Keyed on everything the field depends on, so a changed seed or
        // density is picked up here and needs no didUpdateWidget of its own.
        _ensureParticles(size);
        return CustomPaint(
          painter: SurfaceGrainPainter(
            color: widget.color,
            particles: _particles,
            borderRadius: widget.borderRadius,
            grainOpacity: widget.grainOpacity,
          ),
          child: widget.child,
        );
      },
    );
  }
}

class SurfaceGrainPainter extends CustomPainter {
  SurfaceGrainPainter({
    required this.color,
    required this.particles,
    required this.grainOpacity,
    this.borderRadius,
  });

  final Color color;
  final List<SurfaceGrainParticle> particles;
  final BorderRadius? borderRadius;
  final double grainOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius?.toRRect(rect);

    // Always clipped, radius or not: a speck is placed by its top-left corner
    // anywhere up to the full width/height, so the widest ones would otherwise
    // hang a few pixels outside the plate CustomPaint does not clip for us.
    canvas.save();
    if (rrect != null) {
      canvas.clipRRect(rrect);
    } else {
      canvas.clipRect(rect);
    }

    canvas.drawRect(rect, Paint()..color = color);

    if (particles.isEmpty || grainOpacity <= 0) {
      canvas.restore();
      return;
    }

    // Bidirectional ± luminance: light and dark flecks around the plate.
    final lightBase = Color.lerp(color, Colors.white, 0.07)!;
    final darkBase = Color.lerp(color, Colors.black, 0.1)!;
    final lightPaint = Paint();
    final darkPaint = Paint();

    for (final p in particles) {
      final alpha = (p.opacity * grainOpacity).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      final paint = p.lighter ? lightPaint : darkPaint;
      paint.color = (p.lighter ? lightBase : darkBase).withValues(alpha: alpha);
      final x = p.x * size.width;
      final y = p.y * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, p.size, p.size), paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SurfaceGrainPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.grainOpacity != grainOpacity ||
        oldDelegate.borderRadius != borderRadius ||
        // Identity, not deep equality: the state regenerates the field into a
        // new list only when it actually changed, and reuses the same instance
        // otherwise.
        !identical(oldDelegate.particles, particles);
  }
}

/// Convenience: slightly lower grain when the plate is forced near-solid.
double surfaceGrainOpacityForContrast({required bool nearSolid}) {
  return nearSolid ? 0.01 : 0.025;
}

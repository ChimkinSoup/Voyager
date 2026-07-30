import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A default festive multicolor palette used when an effect doesn't specify its
/// own colors. Bright, saturated hues that read as "confetti" on both light and
/// dark surfaces.
const List<Color> kFestiveConfettiColors = <Color>[
  Color(0xFFEF476F), // pink-red
  Color(0xFFFFD166), // yellow
  Color(0xFF06D6A0), // green
  Color(0xFF118AB2), // blue
  Color(0xFF8338EC), // purple
  Color(0xFFFF7B00), // orange
  Color(0xFF3A86FF), // bright blue
];

/// Immutable description of a one-shot particle burst.
///
/// This is the tuning surface for the [ConfettiOverlay] engine. It's kept
/// generic on purpose: by varying the colors, particle count, spread, speeds,
/// gravity and [scale] you can express many different celebratory effects
/// (a small checkbox "pop", a big milestone shower, a sideways streamer, …)
/// from the same renderer.
///
/// Every distance/speed field is expressed in logical pixels (per second for
/// velocities) and is multiplied by [scale] at spawn time, so a single effect
/// can be uniformly resized with [scaled].
@immutable
class ConfettiEffect {
  const ConfettiEffect({
    this.particleCount = 26,
    this.colors = kFestiveConfettiColors,
    this.minParticleSize = 5,
    this.maxParticleSize = 11,
    this.spread = 1.4,
    this.direction = -math.pi / 2,
    this.minSpeed = 180,
    this.maxSpeed = 380,
    this.gravity = 820,
    this.drift = 34,
    this.duration = const Duration(milliseconds: 1100),
    this.scale = 1,
  });

  /// Number of particles emitted in the burst.
  final int particleCount;

  /// Colors particles are randomly picked from.
  final List<Color> colors;

  /// Smallest particle edge length (logical px, before [scale]).
  final double minParticleSize;

  /// Largest particle edge length (logical px, before [scale]).
  final double maxParticleSize;

  /// Total angular width of the emission cone, in radians.
  final double spread;

  /// Center emission angle, in radians. Screen coordinates: `-pi/2` is straight
  /// up, `0` is to the right, `pi/2` is straight down.
  final double direction;

  /// Slowest launch speed (logical px/s, before [scale]).
  final double minSpeed;

  /// Fastest launch speed (logical px/s, before [scale]).
  final double maxSpeed;

  /// Downward acceleration (logical px/s²). Set to 0 for a weightless burst.
  final double gravity;

  /// Amplitude of the horizontal "flutter" sway (logical px, before [scale]).
  final double drift;

  /// How long the burst lives before it's removed.
  final Duration duration;

  /// Uniform size/speed multiplier — the primary "resize" knob.
  final double scale;

  /// Returns a copy of this effect uniformly resized by [factor] (multiplies
  /// the existing [scale]). Handy for reusing one tuned effect at different
  /// sizes: `effect.scaled(0.5)` for a subtle version, `effect.scaled(2)` big.
  ConfettiEffect scaled(double factor) => copyWith(scale: scale * factor);

  ConfettiEffect copyWith({
    int? particleCount,
    List<Color>? colors,
    double? minParticleSize,
    double? maxParticleSize,
    double? spread,
    double? direction,
    double? minSpeed,
    double? maxSpeed,
    double? gravity,
    double? drift,
    Duration? duration,
    double? scale,
  }) {
    return ConfettiEffect(
      particleCount: particleCount ?? this.particleCount,
      colors: colors ?? this.colors,
      minParticleSize: minParticleSize ?? this.minParticleSize,
      maxParticleSize: maxParticleSize ?? this.maxParticleSize,
      spread: spread ?? this.spread,
      direction: direction ?? this.direction,
      minSpeed: minSpeed ?? this.minSpeed,
      maxSpeed: maxSpeed ?? this.maxSpeed,
      gravity: gravity ?? this.gravity,
      drift: drift ?? this.drift,
      duration: duration ?? this.duration,
      scale: scale ?? this.scale,
    );
  }
}

/// Fires self-contained particle bursts into the app's [Overlay], so effects
/// float above all other UI and outlive the widget that triggered them (a
/// completing to-do row can animate away while its confetti keeps flying).
///
/// The engine is intentionally decoupled from any one feature — call [burst]
/// with an explicit global position, or [burstFromContext] to emit from the
/// center (or any [Alignment]) of the widget that owns a [BuildContext].
abstract final class ConfettiOverlay {
  /// Emits a burst centered on [globalPosition] (in global/screen coordinates).
  static void burst(
    BuildContext context, {
    required Offset globalPosition,
    ConfettiEffect effect = const ConfettiEffect(),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // Translate the global position into the overlay's local coordinate space
    // so the burst lands correctly even if the overlay isn't anchored at the
    // screen origin (window insets, embedded views, etc.).
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final origin = overlayBox != null && overlayBox.hasSize
        ? overlayBox.globalToLocal(globalPosition)
        : globalPosition;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: _ConfettiBurst(
            origin: origin,
            effect: effect,
            onComplete: entry.remove,
          ),
        ),
      ),
    );
    overlay.insert(entry);
  }

  /// Emits a burst from a point on the widget that owns [context].
  ///
  /// [origin] selects where within that widget the burst starts (defaults to
  /// its center). No-op if the context has no laid-out render box yet.
  static void burstFromContext(
    BuildContext context, {
    ConfettiEffect effect = const ConfettiEffect(),
    Alignment origin = Alignment.center,
  }) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = origin.alongSize(box.size);
    burst(
      context,
      globalPosition: box.localToGlobal(local),
      effect: effect,
    );
  }
}

/// A single laid-out particle. All time-varying state is derived analytically
/// from these immutable initial conditions in [_ConfettiPainter], so the burst
/// is deterministic and frame-rate independent.
class _Particle {
  _Particle({
    required this.velocity,
    required this.color,
    required this.holdColor,
    required this.shape,
    required this.rotation,
    required this.rotationSpeed,
    required this.driftPhase,
    required this.drift,
  });

  /// Initial launch velocity in logical px/s.
  final Offset velocity;
  final Color color;

  /// [color] forced fully opaque. Precomputed so the "hold" phase of the burst
  /// (the ~66% before the fade starts) reuses it instead of reallocating a
  /// color every frame. Byte-identical to `color.withValues(alpha: 1)`.
  final Color holdColor;

  /// The particle's rounded rectangle, centered at the origin. Constant for the
  /// particle's whole life — all motion is applied via the canvas transform — so
  /// it's built once at spawn rather than rebuilt every frame.
  final RRect shape;

  /// Initial rotation, radians.
  final double rotation;

  /// Angular velocity, radians/s.
  final double rotationSpeed;

  /// Phase offset so particles don't sway in unison.
  final double driftPhase;

  /// Horizontal sway amplitude for this particle (logical px).
  final double drift;
}

class _ConfettiBurst extends StatefulWidget {
  const _ConfettiBurst({
    required this.origin,
    required this.effect,
    required this.onComplete,
  });

  final Offset origin;
  final ConfettiEffect effect;
  final VoidCallback onComplete;

  @override
  State<_ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<_ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    _particles = _spawn(widget.effect);
    _controller = AnimationController(vsync: this, duration: widget.effect.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onComplete();
      })
      ..forward();
  }

  static List<_Particle> _spawn(ConfettiEffect e) {
    final rnd = math.Random();
    final count = e.particleCount.clamp(1, 500);
    final colors = e.colors.isEmpty ? kFestiveConfettiColors : e.colors;
    return List<_Particle>.generate(count, (_) {
      final angle = e.direction + (rnd.nextDouble() - 0.5) * e.spread;
      final speed =
          (e.minSpeed + rnd.nextDouble() * (e.maxSpeed - e.minSpeed)) * e.scale;
      final size =
          (e.minParticleSize +
              rnd.nextDouble() * (e.maxParticleSize - e.minParticleSize)) *
          e.scale;
      final aspect = 0.4 + rnd.nextDouble() * 0.55;
      final color = colors[rnd.nextInt(colors.length)];
      return _Particle(
        velocity: Offset(math.cos(angle) * speed, math.sin(angle) * speed),
        color: color,
        holdColor: color.withValues(alpha: 1),
        shape: RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: size,
            height: size * aspect,
          ),
          const Radius.circular(1),
        ),
        rotation: rnd.nextDouble() * math.pi * 2,
        rotationSpeed: (rnd.nextDouble() - 0.5) * 12,
        driftPhase: rnd.nextDouble() * math.pi * 2,
        drift: e.drift * e.scale * (0.6 + rnd.nextDouble() * 0.8),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ConfettiPainter(
          origin: widget.origin,
          particles: _particles,
          progress: _controller,
          effect: widget.effect,
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({
    required this.origin,
    required this.particles,
    required this.progress,
    required this.effect,
  }) : super(repaint: progress);

  final Offset origin;
  final List<_Particle> particles;
  final Animation<double> progress;
  final ConfettiEffect effect;

  @override
  void paint(Canvas canvas, Size size) {
    final v = progress.value;
    if (v >= 1) return;
    // Elapsed seconds since launch — drives the analytic motion below.
    final t = v * (effect.duration.inMilliseconds / 1000.0);
    final gravity = effect.gravity;
    // Hold full opacity, then fade over the final third of the burst's life.
    final fade = v < 0.66 ? 1.0 : (1 - (v - 0.66) / 0.34).clamp(0.0, 1.0);

    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in particles) {
      final dx =
          origin.dx +
          p.velocity.dx * t +
          math.sin(t * 6 + p.driftPhase) * p.drift;
      final dy = origin.dy + p.velocity.dy * t + 0.5 * gravity * t * t;
      final rotation = p.rotation + p.rotationSpeed * t;
      // Foreshorten the width on a sine to fake a paper strip tumbling in 3D.
      final flutter = math.cos(t * 8 + p.driftPhase).abs().clamp(0.25, 1.0);

      // During the hold phase [fade] is a constant 1.0, so reuse the precomputed
      // opaque color instead of allocating one per particle per frame.
      paint.color = fade >= 1.0 ? p.holdColor : p.color.withValues(alpha: fade);
      canvas.save();
      canvas.translate(dx, dy);
      canvas.rotate(rotation);
      canvas.scale(flutter, 1);
      canvas.drawRRect(p.shape, paint);
      canvas.restore();
    }
  }

  // Repaint is driven by the [progress] listenable passed to super().
  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => false;
}

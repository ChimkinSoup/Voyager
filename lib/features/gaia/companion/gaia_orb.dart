import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Gaia's loading animation: a sphere of particles that pulses inwards while
/// she's thinking and swirls while her reply is streaming in. It eases
/// between the two, ticks only while on screen ([TickerMode]), and holds
/// still under reduced motion.
class GaiaOrb extends StatefulWidget {
  const GaiaOrb({super.key, required this.speaking, this.size = 40});

  /// Text is arriving; otherwise she's thinking or running tools.
  final bool speaking;

  final double size;

  @override
  State<GaiaOrb> createState() => _GaiaOrbState();
}

class _GaiaOrbState extends State<GaiaOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final _orb = _Orb(speaking: widget.speaking);
  var _lastTick = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced && _ticker.isActive) {
      _ticker.stop();
    } else if (!reduced && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
    _orb.reduced = reduced;
  }

  @override
  void didUpdateWidget(GaiaOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _orb.speaking = widget.speaking;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _orb.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    // Capped, so a stall doesn't jump the orb.
    final dt = min((elapsed - _lastTick).inMicroseconds / 1e6, 0.1);
    _lastTick = elapsed;
    _orb.step(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.speaking ? 'Replying' : 'Thinking',
      liveRegion: true,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(_orb),
        ),
      ),
    );
  }
}

const _count = 720;
const _goldenAngle = pi * (3 - 2.23606797749979);

/// The camera's tilt down onto the sphere.
const _tilt = 0.32;

/// Where the clocks start, so the first frame isn't on a zero crossing.
const _timeOffset = 1.7;

/// Particle colours run from one to the other.
const _from = Color(0xFF8B5CF6);
const _to = Color(0xFFD946EF);

/// The two states' looks, eased between by [_Orb.speakingWeight].
class _Look {
  const _Look({
    required this.spin,
    required this.swell,
    required this.flow,
    required this.swirl,
    required this.pulse,
    required this.jitter,
    required this.alpha,
    required this.rest,
  });

  /// Radians a second about the vertical axis.
  final double spin;

  /// How much the level grows the sphere.
  final double swell;

  /// Streams of particles sinking inwards.
  final double flow;

  /// Latitudes twisting against each other.
  final double swirl;

  /// The heartbeat drawing the sphere in.
  final double pulse;

  final double jitter;
  final double alpha;

  /// The level under reduced motion, standing in for the live one.
  final double rest;

  static _Look lerp(_Look a, _Look b, double t) => _Look(
    spin: lerpDouble(a.spin, b.spin, t)!,
    swell: lerpDouble(a.swell, b.swell, t)!,
    flow: lerpDouble(a.flow, b.flow, t)!,
    swirl: lerpDouble(a.swirl, b.swirl, t)!,
    pulse: lerpDouble(a.pulse, b.pulse, t)!,
    jitter: lerpDouble(a.jitter, b.jitter, t)!,
    alpha: lerpDouble(a.alpha, b.alpha, t)!,
    rest: lerpDouble(a.rest, b.rest, t)!,
  );
}

const _thinkingLook = _Look(
  spin: 0.32,
  swell: 0,
  flow: 0,
  swirl: 0,
  pulse: 1,
  jitter: 0,
  alpha: 0.78,
  rest: 0.3,
);

const _speakingLook = _Look(
  spin: 0.24,
  swell: 0.06,
  flow: 1,
  swirl: 1,
  pulse: 0,
  jitter: 0.6,
  alpha: 0.94,
  rest: 0.55,
);

/// 0 at a trough, 1 at a peak.
double _wave(double x) => 0.5 - 0.5 * cos(x);

/// Eases [current] towards [target], most of the way in 3 / [rate] seconds.
double _approach(double current, double target, double rate, double dt) =>
    current + (target - current) * (1 - exp(-rate * dt));

/// Points spread evenly over a unit sphere by the golden angle, each with a
/// seed for its own wobble and a colour between [_from] and [_to].
class _Sphere {
  _Sphere() {
    for (var i = 0; i < _count; i++) {
      final py = 1 - i / (_count - 1) * 2;
      final r = sqrt(1 - py * py);
      final theta = _goldenAngle * i;
      x[i] = cos(theta) * r;
      y[i] = py;
      z[i] = sin(theta) * r;
      ring[i] = (i * 0.61803398875) % 1;
      seed[i] = (i * 0.7548776662) % 1 * 2 * pi;
      color[i] = _mix((i * 0.5436890126) % 1);
    }
  }

  final x = Float32List(_count), y = Float32List(_count);
  final z = Float32List(_count), ring = Float32List(_count);
  final seed = Float32List(_count);
  final color = List.filled(_count, _from);

  /// Mixed in linear light, so the middle doesn't go muddy.
  static Color _mix(double t) {
    double linear(double c) =>
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
    double srgb(double v) =>
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055;
    double channel(double a, double b) =>
        srgb(linear(a) + (linear(b) - linear(a)) * t);
    return Color.from(
      alpha: 1,
      red: channel(_from.r, _to.r),
      green: channel(_from.g, _to.g),
      blue: channel(_from.b, _to.b),
    );
  }
}

final _sphere = _Sphere();

/// The orb's clocks and eased values. Notifies when they've moved.
class _Orb extends ChangeNotifier {
  _Orb({required bool speaking})
    : _speaking = speaking,
      speakingWeight = speaking ? 1 : 0;

  bool _speaking;
  set speaking(bool value) {
    if (value == _speaking) return;
    _speaking = value;
    // Under reduced motion there's no tick to ease it, so it jumps.
    if (reduced) {
      speakingWeight = value ? 1 : 0;
      notifyListeners();
    }
  }

  var reduced = false;

  /// 0 thinking, 1 speaking; eases over about a fifth of a second.
  double speakingWeight;

  /// Seconds of animation.
  var clock = 0.0;

  /// Rotation about the vertical axis.
  var angle = 0.0;

  /// How lively it is, 0–1, eased from [_energy].
  var level = 0.0;

  _Look get look => _Look.lerp(_thinkingLook, _speakingLook, speakingWeight);

  void step(double dt) {
    speakingWeight = _approach(speakingWeight, _speaking ? 1 : 0, 14, dt);
    clock += dt;
    angle += dt * look.spin;
    final target = _energy(clock);
    // Quick to rise, slow to fall.
    level = _approach(level, target, target > level ? 14 : 4, dt);
    notifyListeners();
  }

  double _energy(double t) {
    final thinking = 0.24 + 0.2 * _wave(t * 4.8);
    final speaking = 0.3 + 0.24 * _wave(t * 12.4) + 0.16 * _wave(t * 6 + 1.2);
    return lerpDouble(thinking, speaking, speakingWeight)!;
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.orb) : super(repaint: orb);

  final _Orb orb;

  @override
  void paint(Canvas canvas, Size size) {
    final p = orb.look;
    final level = orb.reduced ? p.rest : orb.level;
    final t = orb.clock + _timeOffset;
    final center = size.shortestSide / 2;
    // Small orbs pack the same particles into less room: shrink the dots
    // and dim them by how much closer they sit, or they add up to a blob.
    final smallness = min(1.0, size.shortestSide / 140);
    final dotScale = 0.55 + 0.45 * smallness;
    final alphaScale = pow(smallness / dotScale, 2) * p.alpha;

    final beat = sin(t * 2.6) * 0.5 + 0.5;
    final contract = p.pulse * (0.06 + 0.12 * beat * beat * beat);
    final radius =
        center * 0.62 * (1 + 0.01 * sin(t * 1.1) + level * p.swell - contract);
    final jitterAmp = p.jitter * radius * (0.012 + level * 0.07);
    final pulseAmp = p.pulse * 0.16 * (0.4 + 0.6 * beat);
    final flowAmp = p.flow * (0.18 + level * 0.4);
    final swirlAmp = p.swirl * (0.35 + level * 0.9);
    final cosTilt = cos(_tilt), sinTilt = sin(_tilt);
    final s = _sphere;
    final paint = Paint()..blendMode = BlendMode.plus;

    // Particles add up against each other, then the lot lands on the
    // bubble as one.
    canvas.saveLayer(Offset.zero & size, Paint());
    for (var i = 0; i < _count; i++) {
      final twist = swirlAmp > 0.002
          ? orb.angle + swirlAmp * sin(s.y[i] * 2.4 + t * 1.6)
          : orb.angle;
      final cosY = cos(twist), sinY = sin(twist);
      final x1 = s.x[i] * cosY - s.z[i] * sinY;
      final z1 = s.x[i] * sinY + s.z[i] * cosY;
      final y1 = s.y[i] * cosTilt - z1 * sinTilt;
      final z2 = s.y[i] * sinTilt + z1 * cosTilt;
      final depth = (z2 + 1) / 2;
      final perspective = 0.65 + depth * 0.45;

      var r = radius;
      if (pulseAmp > 0.002) {
        r *= 1 - pulseAmp * (0.5 + 0.5 * sin(s.ring[i] * 2 * pi + t * 3.1));
      }
      if (flowAmp > 0.002) {
        final stream = 0.5 + 0.5 * sin(s.seed[i] * 3 - t * 3.4);
        r *= 1 - flowAmp * stream * stream;
      }
      var ox = 0.0, oy = 0.0;
      if (jitterAmp > 0.01) {
        ox = jitterAmp * sin(t * 14 + s.seed[i] * 9.3);
        oy = jitterAmp * cos(t * 17 + s.seed[i] * 6.1);
      }

      paint.color = s.color[i].withValues(
        alpha: (0.12 + depth * depth * 0.78) * alphaScale,
      );
      canvas.drawCircle(
        Offset(
          center + x1 * r * perspective + ox,
          center + y1 * r * perspective + oy,
        ),
        (0.6 + depth * 1.5) * dotScale,
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) => oldDelegate.orb != orb;
}

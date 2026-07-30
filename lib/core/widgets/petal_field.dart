import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/widgets/leaf_shapes.dart';

/// How often each minor color is chosen relative to the primary [Color],
/// indexed by the number of minor colors configured (0-3). Index 0 of the
/// primary is always first in the returned list; the rest follow the minor
/// colors in rank order. See [PetalFieldParams.minorColors].
const List<List<double>> petalColorWeights = [
  [1.0],
  [0.70, 0.30],
  [0.60, 0.25, 0.15],
  [0.50, 0.25, 0.15, 0.10],
];

/// Tunable parameters for the light theme's falling petal field.
///
/// Everything here is exposed to the user in Settings; the field is meant to be
/// dialled from "barely there" to "heavy drift" without touching code.
@immutable
class PetalFieldParams {
  const PetalFieldParams({
    this.color = const Color(0xFFE6A4B4),
    this.minorColors = const [],
    this.maxPetals = 60,
    this.fallSpeed = 34.0,
    this.windFrequency = 0.12,
    this.windStrength = 46.0,
  });

  /// Petal tint. Distinct from the app accent color on purpose.
  final Color color;

  /// Secondary petal tints, ranked top to bottom (first = most common minor
  /// color). Each falling petal randomly picks [color] or one of these,
  /// weighted by [petalColorWeights] according to how many are configured.
  /// Only the first 3 entries are used.
  final List<Color> minorColors;

  /// Ceiling on live petals. The field ramps up to this and never exceeds it.
  final int maxPetals;

  /// Baseline downward speed in logical px/sec, before per-petal size scaling.
  final double fallSpeed;

  /// Frequency of the global wind sine, in Hz. This is what groups the petals:
  /// every live petal samples the same sine at the same instant, so they lean
  /// together instead of each wandering on its own noise.
  final double windFrequency;

  /// Peak horizontal wind speed in logical px/sec.
  final double windStrength;

  static const defaults = PetalFieldParams();

  PetalFieldParams copyWith({
    Color? color,
    List<Color>? minorColors,
    int? maxPetals,
    double? fallSpeed,
    double? windFrequency,
    double? windStrength,
  }) {
    return PetalFieldParams(
      color: color ?? this.color,
      minorColors: minorColors ?? this.minorColors,
      maxPetals: maxPetals ?? this.maxPetals,
      fallSpeed: fallSpeed ?? this.fallSpeed,
      windFrequency: windFrequency ?? this.windFrequency,
      windStrength: windStrength ?? this.windStrength,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PetalFieldParams &&
        other.color == color &&
        listEquals(other.minorColors, minorColors) &&
        other.maxPetals == maxPetals &&
        other.fallSpeed == fallSpeed &&
        other.windFrequency == windFrequency &&
        other.windStrength == windStrength;
  }

  @override
  int get hashCode => Object.hash(
    color,
    Object.hashAll(minorColors),
    maxPetals,
    fallSpeed,
    windFrequency,
    windStrength,
  );
}

/// A localized wind burst.
///
/// This is the mechanism the spec calls a "radial velocity modifier": it lets a
/// gust act on one region of the screen rather than the whole of it, which is
/// what keeps the wind from reading as a single flat global force. Several can
/// be live at once and they simply sum.
///
/// A gust with a [direction] pushes that way; one without pushes *away from*
/// [center], which is the shape a cursor-repelling click burst needs. Nothing
/// currently spawns click bursts — [PetalFieldController.burstAt] is the entry
/// point when that feature lands.
class PetalGust {
  PetalGust({
    required this.center,
    required this.radius,
    required this.strength,
    required this.duration,
    this.direction,
  });

  /// Gust origin in normalized [0,1] screen coordinates, so a gust keeps its
  /// place on screen across a window resize.
  final Offset center;

  /// Radius of influence, in normalized units (fraction of screen width).
  final double radius;

  /// Peak added velocity in logical px/sec at the gust's center.
  final double strength;

  final Duration duration;

  /// Fixed push direction, or null for "radially outward from [center]".
  final Offset? direction;

  double _elapsed = 0;

  bool get isDone => _elapsed >= duration.inMicroseconds / 1e6;

  /// Rises and falls over the gust's life so it never snaps on or off.
  double get _envelope {
    final total = duration.inMicroseconds / 1e6;
    if (total <= 0) return 0;
    final t = (_elapsed / total).clamp(0.0, 1.0);
    return math.sin(t * math.pi);
  }

  /// Added velocity at a petal sitting at [normalized] screen position.
  Offset velocityAt(Offset normalized) {
    final delta = normalized - center;
    final distance = delta.distance;
    if (distance >= radius) return Offset.zero;

    // Smooth falloff to zero at the rim — a linear falloff leaves a visible
    // circular seam where petals abruptly stop being pushed.
    final t = 1.0 - (distance / radius);
    final falloff = t * t * (3.0 - 2.0 * t);
    final magnitude = strength * falloff * _envelope;

    final dir =
        direction ??
        (distance < 1e-4
            ? const Offset(1, 0)
            : Offset(delta.dx / distance, delta.dy / distance));
    return dir * magnitude;
  }
}

/// Handle for pushing wind into a live [PetalField] from outside.
///
/// Exists so interaction features can be added without reworking the
/// simulation: a click handler, a page transition, or a hover effect only needs
/// to call [burstAt].
class PetalFieldController extends ChangeNotifier {
  final List<PetalGust> _pending = [];

  /// Blow petals away from [normalizedPosition] (a point in [0,1] screen
  /// coordinates).
  void burstAt(
    Offset normalizedPosition, {
    double radius = 0.22,
    double strength = 260,
    Duration duration = const Duration(milliseconds: 900),
  }) {
    _pending.add(
      PetalGust(
        center: normalizedPosition,
        radius: radius,
        strength: strength,
        duration: duration,
      ),
    );
    notifyListeners();
  }

  /// Push a region of the screen in a fixed direction.
  void gust(
    Offset normalizedPosition,
    Offset direction, {
    double radius = 0.35,
    double strength = 120,
    Duration duration = const Duration(milliseconds: 1600),
  }) {
    final length = direction.distance;
    _pending.add(
      PetalGust(
        center: normalizedPosition,
        radius: radius,
        strength: strength,
        duration: duration,
        direction: length < 1e-4
            ? const Offset(1, 0)
            : Offset(direction.dx / length, direction.dy / length),
      ),
    );
    notifyListeners();
  }

  List<PetalGust> _drainPending() {
    if (_pending.isEmpty) return const [];
    final drained = List<PetalGust>.of(_pending);
    _pending.clear();
    return drained;
  }
}

/// One petal. Plain mutable state — petals are recycled in place rather than
/// reallocated, so the field never churns the heap once it has ramped up.
class _Petal {
  double x = 0;
  double y = 0;

  /// Current velocity in logical px/sec. Wind is applied to this as an
  /// acceleration rather than being written straight in, so a gust builds and
  /// releases instead of teleporting the petal sideways.
  double vx = 0;
  double vy = 0;

  /// Half-width in logical px.
  double size = 10;

  /// Which sprite this petal is stamped with: 0 is the primary color, 1-3 are
  /// [PetalFieldParams.minorColors] in rank order. Picked once per fall in
  /// [_PetalFieldState._resetPetal] according to [petalColorWeights].
  int colorIndex = 0;

  double rotation = 0;
  double rotationSpeed = 0;

  /// Drives the width squash that reads as the petal turning edge-on.
  double flutterPhase = 0;
  double flutterSpeed = 1;

  /// Personal sway offset so petals in the same wind still don't move in
  /// lockstep. Small compared to the shared wind, which is what preserves the
  /// grouped look.
  double swayPhase = 0;
  double swayAmplitude = 0;

  /// Heavier petals lag the wind. This is the whole reason a gust looks like
  /// air moving through a crowd rather than the crowd sliding as one sheet.
  double drag = 1;

  double opacity = 0;
  double baseOpacity = 0.5;

  /// Seconds spent in the bottom band. Null until the petal enters it.
  double? settleElapsed;

  /// y position at the moment the petal entered the settle band. Used to glide
  /// the petal the rest of the way to the true bottom edge as it settles,
  /// rather than letting it stop wherever its residual velocity runs out.
  double settleStartY = 0;

  bool get settling => settleElapsed != null;
}

/// Semi-translucent watercolor petals fluttering downward over whatever is
/// behind them.
///
/// Strictly stateless in the physical sense the spec asks for: there is no
/// collision engine, no petal-to-petal interaction, and no accumulation at the
/// bottom of the screen. A petal that reaches the bottom 10% decelerates, stops
/// rotating, fades out over [_settleDuration], and is recycled to the top.
///
/// Use inside a [Positioned.fill].
class PetalField extends StatefulWidget {
  const PetalField({
    super.key,
    this.params = PetalFieldParams.defaults,
    this.controller,
    this.spontaneousGusts = true,
  });

  final PetalFieldParams params;

  /// Optional handle for pushing gusts in from outside. See
  /// [PetalFieldController].
  final PetalFieldController? controller;

  /// Whether the field spawns its own occasional localized gusts. Without
  /// these the only wind is the global sine, which acts on the whole screen at
  /// once and never produces a partial burst.
  final bool spontaneousGusts;

  @override
  State<PetalField> createState() => _PetalFieldState();
}

class _PetalFieldState extends State<PetalField> {
  // Driven by a Timer rather than a Ticker for the same reason the geometric
  // background is (see geometric_texture.dart): a Ticker requests a frame on
  // every vsync and pins the whole app's pipeline at the display's refresh
  // rate. A drifting petal gains nothing from 120fps.
  static const _frameInterval = Duration(milliseconds: 16); // ~60fps

  /// How long a petal takes to fade out once it reaches the bottom band.
  static const _settleDuration = 2.0;

  /// Fraction of the screen height that counts as the bottom band.
  static const _settleBandFraction = 0.10;

  final List<_Petal> _petals = [];
  final List<PetalGust> _gusts = [];
  final math.Random _random = math.Random(20260723);

  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  double _time = 0;
  double _lastTick = 0;
  double _nextSpawnAt = 0;
  double _nextGustAt = 0;
  var _tickerModeEnabled = true;

  Size _size = Size.zero;
  List<ui.Image>? _sprites;
  List<Color>? _spriteColors;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _startTimer();
    widget.controller?.addListener(_onControllerBurst);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Same rationale as GeometricTexture: this page can stay mounted offstage
    // (go_router's StatefulShellRoute keeps branches alive for state
    // preservation), and a bare Timer.periodic doesn't know that — it would
    // otherwise keep ticking setState at ~60fps on a tab nobody is looking at.
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled == _tickerModeEnabled) return;
    _tickerModeEnabled = enabled;
    if (enabled) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_frameInterval, (_) => _tick());
  }

  @override
  void didUpdateWidget(covariant PetalField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerBurst);
      widget.controller?.addListener(_onControllerBurst);
    }
    if (oldWidget.params.color != widget.params.color ||
        !listEquals(oldWidget.params.minorColors, widget.params.minorColors)) {
      _disposeSprites();
    }
    if (widget.params.maxPetals < _petals.length) {
      _petals.removeRange(widget.params.maxPetals, _petals.length);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerBurst);
    _timer?.cancel();
    _disposeSprites();
    super.dispose();
  }

  void _disposeSprites() {
    for (final sprite in _sprites ?? const <ui.Image>[]) {
      sprite.dispose();
    }
    _sprites = null;
    _spriteColors = null;
  }

  void _onControllerBurst() {
    _gusts.addAll(widget.controller!._drainPending());
  }

  void _tick() {
    if (!mounted) return;
    if (DevFlags.disablePetalField) return;
    final now = _clock.elapsedMicroseconds / 1e6;
    // Clamp so a stalled or backgrounded app doesn't resume with one enormous
    // step that teleports every petal off screen.
    final dt = math.min(now - _lastTick, 0.1);
    _lastTick = now;
    _time = now;
    if (dt <= 0) return;

    _advance(dt);
    setState(() {});
  }

  void _advance(double dt) {
    if (_size.isEmpty) return;

    _spawnIfNeeded();
    _updateGusts(dt);

    // One sample of the global sine for the entire frame — this is what makes
    // the petals lean together as a group.
    final globalWind =
        math.sin(_time * 2 * math.pi * widget.params.windFrequency) *
        widget.params.windStrength;

    // Decay/approach factors depend only on dt, not on any individual petal, so
    // resolve the transcendentals once per frame instead of once per petal:
    //  - settle velocity/rotation use a fixed base raised to dt;
    //  - the per-petal approach is exp(drag * dt * ln(0.01)), so precompute the
    //    dt*ln(0.01) term and finish it with a single exp per petal below.
    final decay = _FrameDecay(
      settleVelocity: math.pow(0.06, dt).toDouble(),
      settleRotation: math.pow(0.04, dt).toDouble(),
      approachLogDt: math.log(0.01) * dt,
    );

    for (final petal in _petals) {
      _advancePetal(petal, dt, globalWind, decay);
    }
  }

  void _advancePetal(
    _Petal petal,
    double dt,
    double globalWind,
    _FrameDecay decay,
  ) {
    var windX = globalWind;
    var windY = 0.0;
    if (_gusts.isNotEmpty) {
      final normalized = Offset(
        _size.width == 0 ? 0 : petal.x / _size.width,
        _size.height == 0 ? 0 : petal.y / _size.height,
      );
      for (final gust in _gusts) {
        final v = gust.velocityAt(normalized);
        windX += v.dx;
        windY += v.dy;
      }
    }

    // Personal sway rides on top of the shared wind rather than replacing it.
    windX += math.sin(_time * 1.7 + petal.swayPhase) * petal.swayAmplitude;

    final settleBandTop = _size.height * (1.0 - _settleBandFraction);
    final entering = petal.y >= settleBandTop;
    if (entering && !petal.settling) {
      petal.settleElapsed = 0;
      petal.settleStartY = petal.y;
    }

    if (petal.settling) {
      final elapsed = petal.settleElapsed! + dt;
      petal.settleElapsed = elapsed;

      // Graceful stop: velocity, rotation and opacity all wind down together
      // over the same two seconds. No collision, no resting state — the petal
      // is recycled the instant it is invisible. The vertical position is
      // eased explicitly toward the true bottom edge rather than driven by
      // decaying velocity, so every petal actually reaches the bottom instead
      // of stalling wherever its residual speed happened to run out.
      final progress = (elapsed / _settleDuration).clamp(0.0, 1.0);
      final ease = 1.0 - progress;
      final settleEase = 1.0 - ease * ease;
      final targetY = _size.height - petal.size;
      petal.vx *= decay.settleVelocity;
      petal.rotationSpeed *= decay.settleRotation;
      petal.rotation += petal.rotationSpeed * dt;
      petal.flutterPhase += petal.flutterSpeed * dt * ease;
      petal.x += petal.vx * dt;
      petal.y =
          petal.settleStartY + (targetY - petal.settleStartY) * settleEase;
      petal.opacity = petal.baseOpacity * ease * ease;

      if (progress >= 1.0) _resetPetal(petal, fromTop: true);
      return;
    }

    // Wind is an acceleration toward the target velocity, scaled by the
    // petal's drag — light petals whip about, heavy ones lag behind.
    // exp(drag * dt * ln(0.01)) == pow(0.01, dt * drag), with the log resolved
    // once per frame in _FrameDecay.
    final approach = 1.0 - math.exp(petal.drag * decay.approachLogDt);
    petal.vx += (windX - petal.vx) * approach;
    petal.vy +=
        (widget.params.fallSpeed * petal.drag + windY - petal.vy) * approach;

    petal.x += petal.vx * dt;
    petal.y += petal.vy * dt;
    petal.rotation += petal.rotationSpeed * dt;
    petal.flutterPhase += petal.flutterSpeed * dt;

    // Fade in over the first stretch of the fall so petals don't pop into
    // existence at the top edge.
    final fadeInDistance = _size.height * 0.08;
    final entered = (petal.y + petal.size * 2) / (fadeInDistance + 1);
    petal.opacity = petal.baseOpacity * entered.clamp(0.0, 1.0);

    // Horizontal wrap keeps the population stable: a petal blown off one side
    // reappears on the other rather than being destroyed and respawned, which
    // would visibly thin out the field during a strong gust.
    final margin = petal.size * 3;
    if (petal.x < -margin) {
      petal.x = _size.width + margin;
    } else if (petal.x > _size.width + margin) {
      petal.x = -margin;
    }

    // Safety net for a petal driven past the bottom by a strong downward gust
    // before the settle band could catch it.
    if (petal.y > _size.height + margin) _resetPetal(petal, fromTop: true);
  }

  void _updateGusts(double dt) {
    for (final gust in _gusts) {
      gust._elapsed += dt;
    }
    _gusts.removeWhere((g) => g.isDone);

    if (!widget.spontaneousGusts) return;
    if (_time < _nextGustAt) return;

    // Spontaneous gusts are deliberately weak relative to the global wind and
    // cover only part of the screen, so they read as air moving through the
    // scene rather than as a second, competing wind.
    final windward = widget.params.windStrength;
    _gusts.add(
      PetalGust(
        center: Offset(_random.nextDouble(), _random.nextDouble() * 0.8),
        radius: 0.18 + _random.nextDouble() * 0.30,
        strength: windward * (0.35 + _random.nextDouble() * 0.45),
        duration: Duration(milliseconds: 1400 + _random.nextInt(2200)),
        direction: Offset(
          _random.nextBool() ? 1 : -1,
          -0.15 + _random.nextDouble() * 0.5,
        ),
      ),
    );
    _nextGustAt = _time + 2.5 + _random.nextDouble() * 5.0;
  }

  void _spawnIfNeeded() {
    if (_petals.length >= widget.params.maxPetals) return;
    if (_time < _nextSpawnAt) return;

    final petal = _Petal();
    _resetPetal(petal, fromTop: _petals.isNotEmpty);
    _petals.add(petal);

    // Stagger the ramp-up so the field fills in over a few seconds instead of
    // every petal appearing on the same frame in a visible row.
    _nextSpawnAt = _time + 0.08 + _random.nextDouble() * 0.22;
  }

  /// Re-seeds [petal]. [fromTop] false scatters it anywhere on screen, which is
  /// only used while the field is first filling in — otherwise petals would
  /// take a full screen-height of travel before anything is visible.
  void _resetPetal(_Petal petal, {required bool fromTop}) {
    final r = _random;
    petal.size = 5.0 + r.nextDouble() * 7.0;
    petal.x = r.nextDouble() * _size.width;
    petal.y = fromTop
        ? -petal.size * 2 - r.nextDouble() * _size.height * 0.35
        : r.nextDouble() * _size.height * 0.85;
    petal.vx = 0;
    petal.vy = widget.params.fallSpeed;
    petal.rotation = r.nextDouble() * math.pi * 2;
    petal.rotationSpeed = (r.nextDouble() - 0.5) * 1.6;
    petal.flutterPhase = r.nextDouble() * math.pi * 2;
    petal.flutterSpeed = 0.8 + r.nextDouble() * 1.6;
    petal.swayPhase = r.nextDouble() * math.pi * 2;
    petal.swayAmplitude = 4.0 + r.nextDouble() * 10.0;
    // Bigger petals read as nearer and heavier: they fall faster and resist
    // the wind more, which gives the field a sense of depth for free.
    petal.drag = 0.6 + (petal.size - 5.0) / 7.0 * 0.7;
    petal.baseOpacity = 0.28 + r.nextDouble() * 0.34;
    petal.opacity = 0;
    petal.settleElapsed = null;
    petal.colorIndex = _pickColorIndex();
  }

  /// Randomly picks which sprite a newly (re)spawned petal falls with: 0 for
  /// the primary color, or 1-3 for a minor color, weighted by
  /// [petalColorWeights] according to how many minor colors are configured.
  int _pickColorIndex() {
    final minorCount = math.min(widget.params.minorColors.length, 3);
    final weights = petalColorWeights[minorCount];
    final roll = _random.nextDouble();
    var cumulative = 0.0;
    for (var i = 0; i < weights.length; i++) {
      cumulative += weights[i];
      if (roll < cumulative) return i;
    }
    return weights.length - 1;
  }

  /// The petal sprites are rasterized once per color and stamped for every
  /// petal. Building the soft watercolor edge with a gradient and a blur costs
  /// real time; doing it once per color instead of per petal per frame is the
  /// difference between a free background and a hot one.
  List<ui.Image> _spritesFor(List<Color> colors) {
    final cached = _sprites;
    if (cached != null && listEquals(_spriteColors, colors)) return cached;
    _disposeSprites();
    final images = [
      for (final color in colors) buildLeafSprite(LeafDesign.petal, color),
    ];
    _sprites = images;
    _spriteColors = colors;
    return images;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _size) {
          _onResize(size);
        }
        final colors = [
          widget.params.color,
          ...widget.params.minorColors.take(3),
        ];
        return RepaintBoundary(
          child: CustomPaint(
            size: size,
            isComplex: true,
            willChange: true,
            painter: _PetalPainter(
              petals: List<_Petal>.unmodifiable(_petals),
              sprites: _spritesFor(colors),
              repaintTick: _time,
            ),
          ),
        );
      },
    );
  }

  void _onResize(Size size) {
    final old = _size;
    _size = size;
    if (old.isEmpty || size.isEmpty) return;
    // Keep petals where they were relative to the window instead of letting
    // them bunch at the old bounds after a resize.
    final scaleX = size.width / old.width;
    final scaleY = size.height / old.height;
    for (final petal in _petals) {
      petal.x *= scaleX;
      petal.y *= scaleY;
    }
  }
}

/// Stamps the pre-rasterized petal sprite once per petal.
///
/// Each petal gets its own transform because the flutter effect needs a
/// non-uniform scale (the petal narrows as it turns edge-on), which rules out
/// batching them through `drawAtlas`.
class _PetalPainter extends CustomPainter {
  _PetalPainter({
    required this.petals,
    required this.sprites,
    required this.repaintTick,
  });

  final List<_Petal> petals;

  /// One sprite per configured color: index 0 is the primary, 1-3 are the
  /// minor colors in rank order. See [_Petal.colorIndex].
  final List<ui.Image> sprites;

  /// Simulation time. Only used to force a repaint — petal state is mutated in
  /// place, so comparing the list itself would never report a change.
  final double repaintTick;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || petals.isEmpty || sprites.isEmpty) return;

    final paint = Paint()..filterQuality = FilterQuality.low;
    final lastIndex = sprites.length - 1;

    for (final petal in petals) {
      if (petal.opacity <= 0.01) continue;

      // A petal keeps whatever index it was assigned even if the palette
      // shrinks mid-flight — clamp rather than crash on a stale index.
      final sprite = sprites[petal.colorIndex.clamp(0, lastIndex)];
      final src = Rect.fromLTWH(
        0,
        0,
        sprite.width.toDouble(),
        sprite.height.toDouble(),
      );

      // Squashing the width is what sells the flutter: a petal turning through
      // the airflow presents less and less of its face until it flips.
      final squash = math.cos(petal.flutterPhase).abs().clamp(0.12, 1.0);
      final halfW = petal.size * squash;
      final halfH = petal.size;

      canvas.save();
      canvas.translate(petal.x, petal.y);
      canvas.rotate(petal.rotation);
      paint.color = Color.fromRGBO(255, 255, 255, petal.opacity);
      canvas.drawImageRect(
        sprite,
        src,
        Rect.fromLTRB(-halfW, -halfH, halfW, halfH),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PetalPainter oldDelegate) {
    return oldDelegate.repaintTick != repaintTick ||
        !listEquals(oldDelegate.sprites, sprites) ||
        oldDelegate.petals.length != petals.length;
  }
}

/// Per-frame decay factors, resolved once and shared by every petal so the
/// transcendental calls stay out of the per-petal loop. See [_advance].
class _FrameDecay {
  const _FrameDecay({
    required this.settleVelocity,
    required this.settleRotation,
    required this.approachLogDt,
  });

  /// `pow(0.06, dt)` — settling velocity multiplier for this frame.
  final double settleVelocity;

  /// `pow(0.04, dt)` — settling rotation multiplier for this frame.
  final double settleRotation;

  /// `dt * ln(0.01)` — finished per petal as `exp(drag * approachLogDt)`.
  final double approachLogDt;
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The starfield behind Gaia's chat: dim stars turning slowly about a pole
/// above the middle, leaning towards the cursor while it's over them. It
/// ticks only while [active] — Gaia on screen and in front — and turning or
/// with the cursor over it; otherwise, and under reduced motion, it's still.
class GaiaStarfield extends StatefulWidget {
  const GaiaStarfield({
    super.key,
    required this.active,
    this.rotation = 0,
    this.top = 0,
    this.left,
    required this.child,
  });

  final ValueListenable<bool> active;

  /// Degrees a minute the stars turn by themselves, while no [GaiaSky] is
  /// turning them.
  final double rotation;

  /// The stars keep below this, fading at it as at the other edges, so one
  /// can't sit half cut off under an opaque header.
  final double top;

  /// The edge of an opaque sidebar over the stars' left. They stay put as it
  /// moves, so it covers them, but fade out at it.
  final ValueListenable<double>? left;

  final Widget child;

  /// Turns the stars of the starfield behind [context] about a pole above
  /// the middle, by radians, as the [GaiaSky] over them turns.
  static void Function(double radians)? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_StarfieldScope>()?.stars.turn;

  /// Brightens the stars of the starfield behind [context] by a share, 0
  /// to 1, as the [GaiaSky] over them leaves: they're the sky's stars that
  /// stay behind.
  static void Function(double glow)? glowOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_StarfieldScope>()?.stars.setGlow;

  /// How far, in logical pixels, the nearest stars of the starfield behind
  /// [context] lean towards the cursor just now. A [GaiaSky] over them leans
  /// its own by it, each by its depth, so the whole sky leans as one.
  static Offset Function()? leanOf(BuildContext context) {
    final stars = context
        .getInheritedWidgetOfExactType<_StarfieldScope>()
        ?.stars;
    return stars == null ? null : () => stars.lean;
  }

  @override
  State<GaiaStarfield> createState() => _GaiaStarfieldState();
}

class _StarfieldScope extends InheritedWidget {
  const _StarfieldScope({required this.stars, required super.child});

  final _Stars stars;

  @override
  bool updateShouldNotify(_StarfieldScope oldWidget) =>
      oldWidget.stars != stars;
}

/// Enough for the largest chat area; smaller ones draw the first few.
const _pool = 240;

/// Logical pixels of chat area per star.
const _areaPerStar = 6000.0;

/// How far the nearest stars lean towards the cursor, as a share of its
/// distance from the centre.
const _maxLean = 0.03;

/// How often the stars step while only turning, their lean caught up with
/// the cursor, if a step moves them no more than [_maxStepMove]: then it
/// looks the same as one every frame, and the window is still between.
/// Turning faster, they step more often, just often enough.
const _turnStep = Duration(milliseconds: 500);

/// Logical pixels the farthest stars may move in one [_turnStep].
const _maxStepMove = 0.5;

class _GaiaStarfieldState extends State<GaiaStarfield>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _stars = _Stars(Random());

  /// The frame of the last step, so the next knows how long it's been,
  /// frames or not between them; null when stopped.
  Duration? _lastTick;

  /// Set while waiting out a [_turnStep].
  Timer? _wake;
  var _reduced = false;
  var _hovered = false;

  @override
  void initState() {
    super.initState();
    _stars.rate = widget.rotation * pi / 180 / 60;
    widget.active.addListener(_sync);
  }

  @override
  void didUpdateWidget(GaiaStarfield oldWidget) {
    super.didUpdateWidget(oldWidget);
    _stars.rate = widget.rotation * pi / 180 / 60;
    if (oldWidget.active != widget.active) {
      oldWidget.active.removeListener(_sync);
      widget.active.addListener(_sync);
    }
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) _stars.settle();
    _sync();
  }

  @override
  void dispose() {
    widget.active.removeListener(_sync);
    _wake?.cancel();
    _ticker.dispose();
    _stars.dispose();
    super.dispose();
  }

  void _sync() {
    final run =
        widget.active.value && (_hovered || _stars.rate > 0) && !_reduced;
    if (!run) {
      _wake?.cancel();
      _wake = null;
      _ticker.stop();
      _lastTick = null;
      return;
    }
    // Waiting out a step, unless the cursor moved: leaning follows it.
    if (_wake != null && _stars.settled) return;
    _wake?.cancel();
    _wake = null;
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration _) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Capped, so a stall doesn't jump the field.
    final dt = switch (_lastTick) {
      final last? => min((now - last).inMicroseconds / 1e6, 0.25),
      null => 0.0,
    };
    _lastTick = now;
    _stars.step(dt);
    if (!_stars.settled) return;
    _ticker.stop();
    // No step moving them more than [_maxStepMove].
    final step = min(
      _turnStep.inMicroseconds / 1e6,
      _maxStepMove / _stars.drift,
    );
    _wake = Timer(Duration(microseconds: (step * 1e6).round()), () {
      _wake = null;
      _sync();
    });
  }

  /// Every move, not only coming and going: a step being waited out
  /// gives way to every frame while the lean catches up.
  void _hover(bool hovered) {
    _hovered = hovered;
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      onHover: (event) {
        _stars.cursor = event.localPosition - Offset(0, widget.top);
        _hover(true);
      },
      onExit: (_) {
        _stars.cursor = null;
        _hover(false);
      },
      // Boundaries on both sides, so a frame repaints only the stars: not
      // the chat in front of them, nor the window around them.
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _StarPainter(_stars, widget.top, widget.left),
          child: RepaintBoundary(
            child: _StarfieldScope(stars: _stars, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// The stars' state, in a share of the area so a resize keeps the field.
/// Notifies when they've moved.
class _Stars extends ChangeNotifier {
  _Stars(Random random)
    : x = Float32List.fromList([
        for (var i = 0; i < _pool; i++) random.nextDouble(),
      ]),
      y = Float32List.fromList([
        for (var i = 0; i < _pool; i++) random.nextDouble(),
      ]),
      radius = Float32List.fromList([
        for (var i = 0; i < _pool; i++) random.nextBool() ? 0.4 : 1.4,
      ]),
      alpha = Float32List.fromList([
        for (var i = 0; i < _pool; i++) 0.1 + random.nextDouble() * 0.6,
      ]),
      depth = Float32List.fromList([
        for (var i = 0; i < _pool; i++) 0.03 + random.nextDouble() * 0.97,
      ]);

  final Float32List x, y, radius, alpha, depth;

  /// Where the nearest stars' lean has eased to, in logical pixels: each
  /// leans by it times its [depth], all easing alike.
  var lean = Offset.zero;

  /// Logical, from the top left; null while the cursor is elsewhere.
  Offset? cursor;

  /// Set by each paint.
  var size = Size.zero;

  /// Radians a second the stars turn by themselves.
  var rate = 0.0;

  /// Logical pixels a second the farthest stars, at the bottom corners,
  /// move as they turn by themselves.
  double get drift => rate * Offset(size.width / 2, size.height * 1.5).distance;

  /// A sky turned them since the last step, so they don't turn themselves.
  var _driven = false;

  /// How much brighter they are, 0 to 1.
  var glow = 0.0;

  /// Where [lean] is easing to: towards the cursor, or back to rest.
  Offset get _aim => cursor == null || size.isEmpty
      ? Offset.zero
      : (cursor! - size.center(Offset.zero)) * _maxLean;

  /// The lean has caught up with the cursor, or come to rest without it.
  bool get settled => (_aim - lean).distance < 0.01;

  void setGlow(double value) {
    if (value == glow) return;
    glow = value;
    notifyListeners();
  }

  void step(double dt) {
    if (size.isEmpty) return;
    // Eases most of the way in about a second.
    final ease = 1 - exp(-dt / 0.4);
    // Anticlockwise, as the sky turns.
    if (!_driven) _turn(-rate * dt);
    _driven = false;
    lean += (_aim - lean) * ease;
    notifyListeners();
  }

  /// Turns the stars by [radians] about a pole half the field's height
  /// above its middle, wrapping at the edges. That turning carries as many
  /// stars across each edge as come in at the opposite one, so the field
  /// stays even.
  void turn(double radians) {
    _driven = true;
    _turn(radians);
  }

  void _turn(double radians) {
    if (size.isEmpty || radians == 0) return;
    final w = size.width, h = size.height;
    final c = cos(radians), s = sin(radians);
    for (var i = 0; i < _pool; i++) {
      final px = x[i] * w - w / 2, py = y[i] * h + h / 2;
      x[i] = (w / 2 + px * c - py * s) / w % 1;
      y[i] = (px * s + py * c - h / 2) / h % 1;
    }
    notifyListeners();
  }

  /// Drops the lean, for reduced motion.
  void settle() {
    lean = Offset.zero;
    notifyListeners();
  }
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.stars, this.top, this.left)
    : super(repaint: Listenable.merge([stars, left]));

  final _Stars stars;
  final double top;
  final ValueListenable<double>? left;

  /// Stars fade out over this distance from the edges, so wrapping round
  /// doesn't pop.
  static const _edge = 20.0;

  static const _minRadius = 1.0;

  @override
  void paint(Canvas canvas, Size whole) {
    final size = Size(whole.width, max(0, whole.height - top));
    canvas.translate(0, top);
    stars.size = size;
    final count = min(_pool, (size.width * size.height / _areaPerStar).ceil());
    final paint = Paint();
    final from = max(0.0, left?.value ?? 0);
    final glow = 1 + stars.glow;
    for (var i = 0; i < count; i++) {
      final px = stars.x[i] * size.width + stars.lean.dx * stars.depth[i];
      final py = stars.y[i] * size.height + stars.lean.dy * stars.depth[i];
      final r = stars.radius[i];
      final nearest = min(
        min(px - from - r, size.width - px - r),
        min(py - r, size.height - py - r),
      );
      if (nearest <= 0) continue;
      // No smaller than a pixel or so across, dimmed to give the same light:
      // a smaller dot flashes as it moves, bright on a pixel and dim
      // between two.
      final drawn = max(r, _minRadius);
      final alpha = min(
        1.0,
        stars.alpha[i] *
            glow *
            min(nearest / _edge, 1) *
            (r / drawn) *
            (r / drawn),
      );
      paint.color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(Offset(px, py), drawn, paint);
    }
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) =>
      oldDelegate.stars != stars ||
      oldDelegate.top != top ||
      oldDelegate.left != left;
}

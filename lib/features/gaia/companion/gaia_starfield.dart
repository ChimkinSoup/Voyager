import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The starfield behind Gaia's chat: dim stars that drift and lean towards
/// the cursor while it's over them. It ticks only while [active] — Gaia on
/// screen and in front — with the cursor over it, so a window left alone
/// costs nothing; otherwise, and under reduced motion, it's still.
class GaiaStarfield extends StatefulWidget {
  const GaiaStarfield({
    super.key,
    required this.active,
    this.top = 0,
    this.left,
    required this.child,
  });

  final ValueListenable<bool> active;

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

class _GaiaStarfieldState extends State<GaiaStarfield>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _stars = _Stars(Random());
  var _lastTick = Duration.zero;
  var _reduced = false;
  var _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.active.addListener(_sync);
  }

  @override
  void didUpdateWidget(GaiaStarfield oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    oldWidget.active.removeListener(_sync);
    widget.active.addListener(_sync);
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
    _ticker.dispose();
    _stars.dispose();
    super.dispose();
  }

  void _sync() {
    final run = widget.active.value && _hovered && !_reduced;
    if (run == _ticker.isActive) return;
    if (run) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    // Capped, so a stall doesn't jump the field.
    final dt = min((elapsed - _lastTick).inMicroseconds / 1e6, 0.1);
    _lastTick = elapsed;
    _stars.step(dt);
  }

  void _hover(bool hovered) {
    if (hovered == _hovered) return;
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
      // Logical pixels a second.
      dx = Float32List.fromList([
        for (var i = 0; i < _pool; i++) (random.nextDouble() - 0.5) * 6,
      ]),
      dy = Float32List.fromList([
        for (var i = 0; i < _pool; i++) (random.nextDouble() - 0.5) * 6,
      ]),
      depth = Float32List.fromList([
        for (var i = 0; i < _pool; i++) 0.03 + random.nextDouble() * 0.97,
      ]);

  final Float32List x, y, radius, alpha, dx, dy, depth;

  /// Where each star's lean has eased to, in logical pixels.
  final leanX = Float32List(_pool), leanY = Float32List(_pool);

  /// Logical, from the top left; null while the cursor is elsewhere.
  Offset? cursor;

  /// Set by each paint.
  var size = Size.zero;

  void step(double dt) {
    if (size.isEmpty) return;
    final target = cursor == null
        ? Offset.zero
        : cursor! - size.center(Offset.zero);
    // Eases most of the way in about a second.
    final ease = 1 - exp(-dt / 0.4);
    for (var i = 0; i < _pool; i++) {
      x[i] = (x[i] + dx[i] * dt / size.width) % 1;
      y[i] = (y[i] + dy[i] * dt / size.height) % 1;
      leanX[i] += (target.dx * _maxLean * depth[i] - leanX[i]) * ease;
      leanY[i] += (target.dy * _maxLean * depth[i] - leanY[i]) * ease;
    }
    notifyListeners();
  }

  /// Turns the stars by [radians] about a pole half the field's height
  /// above its middle, wrapping at the edges. That turning carries as many
  /// stars across each edge as come in at the opposite one, so the field
  /// stays even.
  void turn(double radians) {
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
    leanX.fillRange(0, _pool, 0);
    leanY.fillRange(0, _pool, 0);
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
    for (var i = 0; i < count; i++) {
      final px = stars.x[i] * size.width + stars.leanX[i];
      final py = stars.y[i] * size.height + stars.leanY[i];
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
      final alpha =
          stars.alpha[i] * min(nearest / _edge, 1) * (r / drawn) * (r / drawn);
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

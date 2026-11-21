import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// The starfield behind Gaia's chat: dim stars turning slowly about a pole
/// above the middle, leaning towards the cursor while it's over them. It
/// ticks only while [active] — Gaia on screen and in front — and turning or
/// with the cursor over it; otherwise, and under reduced motion, it's still.
class GaiaStarfield extends StatefulWidget {
  const GaiaStarfield({
    super.key,
    required this.active,
    this.rotation = 0,
    this.maxStepMove = _maxStepMove,
    this.top = 0,
    this.left,
    this.placing = false,
    this.under,
    required this.child,
  });

  final ValueListenable<bool> active;

  /// Degrees a minute the stars turn by themselves, while no [GaiaSky] is
  /// turning them.
  final double rotation;

  /// Logical pixels the farthest stars may move in one step while only
  /// turning.
  final double maxStepMove;

  /// The stars keep below this, fading at it as at the other edges, so one
  /// can't sit half cut off under an opaque header.
  final double top;

  /// The edge of an opaque sidebar over the stars' left. They stay put as it
  /// moves, so it covers them, but fade out at it.
  final ValueListenable<double>? left;

  /// How far the chat's messages run under its header and composer
  /// ([GaiaController.scrolledUnder]). The fades over those edges paint the
  /// surface over the stars too, as much as that; the stars there are drawn
  /// brighter by as much, so they show the fades' full strength however far
  /// the chat's scrolled.
  final ValueListenable<({double header, double composer})>? under;

  /// Debug: Ctrl+click places a star, which Ctrl+drag moves and
  /// Ctrl+right-click takes away. They go when this does.
  final bool placing;

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

  /// Fades the stars of the starfield behind [context] out round the
  /// composer's field, [box] in global coordinates; null once it's gone.
  static void Function(RRect? box)? clearOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_StarfieldScope>()?.clear;

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
  const _StarfieldScope({
    required this.stars,
    required this.clear,
    required super.child,
  });

  final _Stars stars;
  final void Function(RRect? box) clear;

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

  /// Ctrl is held while [GaiaStarfield.placing]: the stars take the
  /// clicks, not the chat.
  var _ctrl = false;

  /// The placed star, or cluster, being dragged.
  int? _dragging;

  @override
  void initState() {
    super.initState();
    _stars.rate = widget.rotation * pi / 180 / 60;
    widget.active.addListener(_sync);
    HardwareKeyboard.instance.addHandler(_key);
  }

  bool _key(KeyEvent _) {
    final ctrl = widget.placing && HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrl) setState(() => _ctrl = ctrl);
    return false;
  }

  /// [local] in the stars' own space, below [GaiaStarfield.top].
  Offset _field(Offset local) => local - Offset(0, widget.top);

  /// [global], the composer's field, into the stars' space.
  void _clear(RRect? global) {
    final box = context.findRenderObject();
    if (global == null || box is! RenderBox || !box.attached) {
      return _stars.setClear(null);
    }
    // Through the transform, not a shift: Gaia's zoom scales both.
    final rect = Rect.fromPoints(
      box.globalToLocal(global.outerRect.topLeft),
      box.globalToLocal(global.outerRect.bottomRight),
    ).shift(Offset(0, -widget.top));
    _stars.setClear(RRect.fromRectAndRadius(rect, global.tlRadius));
  }

  @override
  void didUpdateWidget(GaiaStarfield oldWidget) {
    super.didUpdateWidget(oldWidget);
    _stars.rate = widget.rotation * pi / 180 / 60;
    if (oldWidget.placing && !widget.placing) {
      _ctrl = false;
      _stars.unplace();
    }
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
    HardwareKeyboard.instance.removeHandler(_key);
    _wake?.cancel();
    _ticker.dispose();
    _stars.dispose();
    super.dispose();
  }

  void _sync() {
    // Ctrl let go in another app sends no key-up here.
    if (!widget.active.value && _ctrl) setState(() => _ctrl = false);
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
    // Capped, so a stall doesn't jump the field; above a [_turnStep], so a
    // step turns the stars as far as the time it waited out.
    final dt = switch (_lastTick) {
      final last? => min((now - last).inMicroseconds / 1e6, 0.6),
      null => 0.0,
    };
    _lastTick = now;
    _stars.step(dt);
    if (!_stars.settled) return;
    _ticker.stop();
    // No step moving them more than [_maxStepMove].
    final step = min(
      _turnStep.inMicroseconds / 1e6,
      widget.maxStepMove / _stars.drift,
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
          painter: _StarPainter(
            _stars,
            widget.top,
            widget.left,
            widget.under,
          ),
          child: RepaintBoundary(
            child: _StarfieldScope(
              stars: _stars,
              clear: _clear,
              // A stack throughout, so the chat isn't rebuilt from scratch as
              // the placing layer comes and goes.
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  widget.child,
                  if (_ctrl)
                    Positioned.fill(
                      child: MouseRegion(
                        cursor: SystemMouseCursors.precise,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // Ctrl+Shift always makes a new cluster; Ctrl
                          // picks up the star or cluster under the cursor,
                          // else places a star.
                          onPanDown: (details) {
                            final at = _field(details.localPosition);
                            _dragging = HardwareKeyboard.instance.isShiftPressed
                                ? _stars.placeCluster(at)
                                : _stars.nearestPlaced(at) ?? _stars.place(at);
                          },
                          onPanUpdate: (details) {
                            if (_dragging case final i?) {
                              _stars.dragPlaced(
                                i,
                                _field(details.localPosition),
                              );
                            }
                          },
                          onPanEnd: (_) => _dragging = null,
                          onPanCancel: () => _dragging = null,
                          onSecondaryTapUp: (details) {
                            final at = _field(details.localPosition);
                            if (_stars.nearestPlaced(at) case final i?) {
                              _stars.removePlaced(i);
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The stars' colours, white first, as the sky's are too: blue-white, warm,
/// blue, yellow-orange and red-orange.
const kGaiaStarTints = [
  Color(0xFFFFFFFF),
  Color(0xFFCFDDFF),
  Color(0xFFFFE6C8),
  Color(0xFF9DB8FF),
  Color(0xFFFFD58F),
  Color(0xFFFFA877),
];

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
      ]),
      // Shown only on the larger stars: the eye sees faint ones white.
      tint = Uint8List.fromList([
        for (var i = 0; i < _pool; i++)
          random.nextDouble() < 0.45
              ? 1 + random.nextInt(kGaiaStarTints.length - 1)
              : 0,
      ]);

  final Float32List x, y, radius, alpha, depth;

  /// Each star's colour, of [kGaiaStarTints].
  final Uint8List tint;

  /// Stars placed by hand, each a lone star or a cluster of them, in a
  /// share of the area as the rest are: drawn as the nearest, brightest of
  /// them ([placedRadius], [placedAlpha], depth 1).
  final placed = <List<Offset>>[];

  static const placedRadius = 1.4;
  static const placedAlpha = 0.7;

  /// Logical pixels from a placed star a click picks it up within.
  static const _pick = 16.0;

  /// A cluster's stars, and the radius, in logical pixels, they're
  /// scattered within.
  static const _clusterStars = 12;
  static const _clusterRadius = 18.0;

  /// Logical pixels a dragged star keeps above the cursor, so it can be
  /// seen; a cluster keeps its whole radius further.
  static const _dragGap = 20.0;

  /// The placed star or cluster with a star nearest [at], in the stars'
  /// space, if one's in reach.
  int? nearestPlaced(Offset at) {
    int? found;
    var best = _pick;
    for (var i = 0; i < placed.length; i++) {
      for (final share in placed[i]) {
        final drawn = _pixels(share) + lean;
        final distance = (drawn - at).distance;
        if (distance < best) {
          best = distance;
          found = i;
        }
      }
    }
    return found;
  }

  Offset _pixels(Offset share) =>
      Offset(share.dx * size.width, share.dy * size.height);

  Offset _share(Offset pixels) =>
      Offset(pixels.dx / size.width, pixels.dy / size.height);

  /// Places a star at [at], returning its index.
  int place(Offset at) {
    placed.add([_share(at - lean)]);
    notifyListeners();
    return placed.length - 1;
  }

  /// Places a cluster of stars scattered evenly in a small circle about
  /// [at], returning its index.
  int placeCluster(Offset at) {
    final random = Random();
    placed.add([
      for (var i = 0; i < _clusterStars; i++)
        _share(
          at -
              lean +
              Offset.fromDirection(
                random.nextDouble() * 2 * pi,
                _clusterRadius * sqrt(random.nextDouble()),
              ),
        ),
    ]);
    notifyListeners();
    return placed.length - 1;
  }

  /// Moves placed star or cluster [i] so its middle sits a little above
  /// [cursor].
  void dragPlaced(int i, Offset cursor) {
    final group = placed[i];
    final gap = _dragGap + (group.length > 1 ? _clusterRadius : 0);
    final middle =
        group.fold(Offset.zero, (sum, share) => sum + _pixels(share)) /
        group.length.toDouble();
    final by = _share(cursor - Offset(0, gap) - lean - middle);
    for (var j = 0; j < group.length; j++) {
      group[j] += by;
    }
    notifyListeners();
  }

  void removePlaced(int i) {
    placed.removeAt(i);
    notifyListeners();
  }

  void unplace() {
    placed.clear();
    notifyListeners();
  }

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

  /// The composer's field, which the stars fade out round, in their space.
  RRect? clear;

  void setClear(RRect? value) {
    if (value == clear) return;
    clear = value;
    notifyListeners();
  }

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
    for (final group in placed) {
      for (var i = 0; i < group.length; i++) {
        final px = group[i].dx * w - w / 2, py = group[i].dy * h + h / 2;
        group[i] = Offset(
          (w / 2 + px * c - py * s) / w % 1,
          (px * s + py * c - h / 2) / h % 1,
        );
      }
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
  _StarPainter(this.stars, this.top, this.left, this.under)
    : super(repaint: Listenable.merge([stars, left, under]));

  final _Stars stars;
  final double top;
  final ValueListenable<double>? left;
  final ValueListenable<({double header, double composer})>? under;

  /// Stars fade out over this distance from the edges, so wrapping round
  /// doesn't pop.
  static const _edge = 20.0;

  /// Stars fade out over this distance from the composer's field, so its
  /// edge doesn't cut through them.
  static const _clearEdge = 6.0;

  /// How far ([x], [y]) is outside [box]'s rounded outline.
  static double _outside(RRect box, double x, double y) {
    final radius = box.tlRadiusX;
    final dx = max(max(box.left + radius - x, x - box.right + radius), 0.0);
    final dy = max(max(box.top + radius - y, y - box.bottom + radius), 0.0);
    return sqrt(dx * dx + dy * dy) - radius;
  }

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
    final shown = under?.value;
    final field = stars.clear?.top;
    const fade = kGaiaChatFade;
    // How much of a star at [py] shows past the chat's fades over its header
    // (the stars' top) and its composer's field, which cover it [shown]:
    // what makes theirs up to the full fade.
    double dim(double py) {
      if (shown == null) return 1;
      var full = 0.0, over = 0.0;
      if (py < fade) {
        full = gaiaFadeAt(1 - py / fade);
        over = full * shown.header;
      } else if (field != null && py > field - fade && py < field) {
        full = gaiaFadeAt(1 - (field - py) / fade);
        over = full * shown.composer;
      }
      if (full == 0) return 1;
      return over >= 1 ? 0 : (1 - full) / (1 - over);
    }

    void star(
      double x,
      double y,
      double r,
      double a,
      double depth, [
      int tint = 0,
    ]) {
      final px = x * size.width + stars.lean.dx * depth;
      final py = y * size.height + stars.lean.dy * depth;
      final nearest = min(
        min(px - from - r, size.width - px - r),
        min(py - r, size.height - py - r),
      );
      if (nearest <= 0) return;
      final clear = stars.clear;
      final around = clear == null ? _clearEdge : _outside(clear, px, py) - r;
      if (around <= 0) return;
      // No smaller than a pixel or so across, dimmed to give the same light:
      // a smaller dot flashes as it moves, bright on a pixel and dim
      // between two.
      final drawn = max(r, _minRadius);
      final alpha = min(
        1.0,
        a *
            glow *
            min(nearest / _edge, 1) *
            min(around / _clearEdge, 1) *
            (r / drawn) *
            (r / drawn),
      );
      paint.color = kGaiaStarTints[r > 1 ? tint : 0].withValues(
        alpha: alpha * dim(py),
      );
      canvas.drawCircle(Offset(px, py), drawn, paint);
    }

    for (var i = 0; i < count; i++) {
      star(
        stars.x[i],
        stars.y[i],
        stars.radius[i],
        stars.alpha[i],
        stars.depth[i],
        stars.tint[i],
      );
    }
    for (final group in stars.placed) {
      for (final at in group) {
        star(at.dx, at.dy, _Stars.placedRadius, _Stars.placedAlpha, 1);
      }
    }
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) =>
      oldDelegate.stars != stars ||
      oldDelegate.top != top ||
      oldDelegate.left != left ||
      oldDelegate.under != under;
}

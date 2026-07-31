import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/leaf_shapes.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// A localized shudder applied to nearby foliage — the "gust" a blossom popup
/// kicks up when it opens. Same falloff/envelope shape as [PetalGust][the
/// falling-petal field's gust], but it shakes the clumps near the popup
/// rather than pushing individual petals.
class _LeafShudder {
  _LeafShudder({required this.center, required this.radius, required this.strength});

  final Offset center;
  final double radius;
  final double strength;
  double _elapsed = 0;

  static const _duration = 1.1;

  bool get isDone => _elapsed >= _duration;

  double extraAt(Offset normalized) {
    final distance = (normalized - center).distance;
    if (distance >= radius) return 0;
    final t = 1.0 - (distance / radius);
    final falloff = t * t * (3.0 - 2.0 * t);
    final envelope = math.sin((_elapsed / _duration).clamp(0.0, 1.0) * math.pi);
    return strength * falloff * envelope;
  }
}

/// One leaf currently animating from its canopy anchor down to the ground,
/// as part of the first-run opening animation.
class _FallingLeaf {
  _FallingLeaf({required this.leafIndex, required this.startDelay});

  final int leafIndex;
  final double startDelay;
  double elapsed = 0;

  static const _fallDuration = 1.4;

  double get progress =>
      ((elapsed - startDelay) / _fallDuration).clamp(0.0, 1.0);

  bool get isDone => elapsed - startDelay >= _fallDuration;
  bool get hasStarted => elapsed >= startDelay;
}

/// Deterministic landing spot + rest rotation for a fallen leaf, keyed only
/// by its index — so grounded leaves never need their own persisted
/// position, just the fact that they landed (see [LifeTreeCanvasController]).
/// Landing spots are biased toward the tree's footprint rather than spread
/// edge to edge, so the drift reads as having fallen from the canopy above.
Offset groundPositionFor(int leafIndex) {
  final r = math.Random(leafIndex * 7919 + 13);
  final spread = (r.nextDouble() + r.nextDouble()) / 2;
  return Offset(0.12 + spread * 0.76, 0.878 + r.nextDouble() * 0.070);
}

double groundRotationFor(int leafIndex) {
  return math.Random(leafIndex * 104729 + 31).nextDouble() * math.pi * 2;
}

/// Imperative handle for triggering the blossom-gust shudder and the
/// first-run opening fall, mirroring [PetalFieldController]'s burst API.
class LifeTreeCanvasController extends ChangeNotifier {
  final List<_LeafShudder> _pendingGusts = [];
  List<int>? _pendingFallIndices;
  VoidCallback? _pendingFallOnDone;

  /// Shudders the foliage near [normalizedPosition] — called when a blossom
  /// popup opens, so the tree visibly reacts.
  void gustAt(Offset normalizedPosition, {double radius = 0.22, double strength = 0.55}) {
    _pendingGusts.add(
      _LeafShudder(center: normalizedPosition, radius: radius, strength: strength),
    );
    notifyListeners();
  }

  /// Starts the first-run opening animation: [leafIndices] fall and settle on
  /// the ground; [onDone] fires once every leaf has landed so the caller can
  /// persist the grounded set.
  void startOpeningFall(List<int> leafIndices, VoidCallback onDone) {
    _pendingFallIndices = leafIndices;
    _pendingFallOnDone = onDone;
    notifyListeners();
  }

  /// Puts every leaf back on the tree, abandoning any fall in progress. The
  /// caller is responsible for clearing the persisted grounded set too — see
  /// the Life Tracker page's replay button.
  void resetFall() {
    _pendingReset = true;
    notifyListeners();
  }

  bool _pendingReset = false;
}

/// Expands the petal palette into light tint / base / deep shade for each
/// colour. A stippled crown reads as flat and synthetic if every speck is the
/// same pink; the reference painting's depth comes entirely from mixing pale
/// blossom, mid pink and near-crimson accents across the same mass.
List<Color> buildTonePalette(List<Color> base) {
  final palette = <Color>[];
  for (var i = 0; i < 4; i++) {
    final color = base[i % base.length];
    palette
      ..add(Color.lerp(color, Colors.white, 0.46)!)
      ..add(color)
      ..add(Color.lerp(color, const Color(0xFF63122B), 0.52)!);
  }
  return palette;
}

class LifeTreeCanvas extends StatefulWidget {
  const LifeTreeCanvas({
    super.key,
    required this.geometry,
    required this.leafColors,
    required this.inkColor,
    required this.groundColor,
    required this.groundedLeafIndices,
    required this.controller,
  });

  final LifeTreeGeometry geometry;

  /// Index 0 is the primary leaf tint, 1-3 are minor tints — same convention
  /// as [PetalFieldParams.minorColors]. Expanded into tones by
  /// [buildTonePalette] before anything is painted.
  final List<Color> leafColors;

  /// Pigment the woody parts and the paper grain are painted in. Passed in
  /// rather than fixed so it can stay legible in both themes.
  final Color inkColor;

  /// Pigment of the shadow pooled under the tree.
  final Color groundColor;

  /// Leaves already permanently grounded from a previous run this session.
  final Set<int> groundedLeafIndices;
  final LifeTreeCanvasController controller;

  @override
  State<LifeTreeCanvas> createState() => _LifeTreeCanvasState();
}

class _LifeTreeCanvasState extends State<LifeTreeCanvas> {
  static const _frameInterval = Duration(milliseconds: 16);
  static const _spriteExtent = 96.0;

  /// Alpha baked into every petal sprite (0-255). Stipple specks want to read
  /// as distinct flecks of pigment, so they sit near full strength — the
  /// translucency in this painting comes from the paper showing between them,
  /// not from each speck being faint.
  static const _leafAlpha = 226;

  static const _grainExtent = 128;

  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  double _time = 0;
  double _lastTick = 0;
  var _tickerModeEnabled = true;

  final List<_LeafShudder> _gusts = [];
  final Map<int, _FallingLeaf> _falling = {};
  final Set<int> _landedThisSession = {};

  ui.Image? _atlas;
  List<Color>? _atlasColors;
  late List<Rect> _leafCellRects;

  ui.Image? _grain;
  Color? _grainInk;
  ui.ImageShader? _grainShader;

  // Every leaf is drawn every frame — attached, falling or landed — so the
  // atlas buffers are allocated once and refilled in place rather than
  // rebuilding 4160 transform objects sixty times a second.
  late final Float32List _rstBuffer =
      Float32List(widget.geometry.leaves.length * 4);
  late final Float32List _rectBuffer =
      Float32List(widget.geometry.leaves.length * 4);

  // Resting places, resolved once. These are derived from the leaf index
  // alone, but deriving them seeds a Random per leaf — and every grounded or
  // falling leaf needs both of them on every frame.
  late final List<Offset> _restPositions = [
    for (var i = 0; i < widget.geometry.leaves.length; i++) groundPositionFor(i),
  ];
  late final Float32List _restRotations = Float32List.fromList([
    for (var i = 0; i < widget.geometry.leaves.length; i++) groundRotationFor(i),
  ]);

  // The ground pool, all 66 clump washes and the whole woody skeleton are
  // static, but painting them costs a saveLayer and ~20 blurred fills per
  // clump. A ui.Picture is a display list, not a texture, so drawing one
  // re-runs every one of those blurs — replaying it each frame is what pinned
  // this page at a few fps. Rasterize it once instead and blit the result.
  ui.Image? _background;
  ui.Picture? _splatterPicture;
  Size? _sceneSize;
  double? _sceneDpr;
  List<Color>? _sceneColors;
  Color? _sceneInk;
  Color? _sceneGround;

  /// Ceiling on the backing texture's resolution. The background is soft
  /// washes and blurred wood, so there is nothing to gain from rendering it
  /// beyond this, and the memory saving on a hidpi display is large.
  static const _maxBackgroundScale = 2.0;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _startTimer();
    widget.controller.addListener(_onControllerEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
  void dispose() {
    widget.controller.removeListener(_onControllerEvent);
    _timer?.cancel();
    _atlas?.dispose();
    _grain?.dispose();
    _disposeScene();
    super.dispose();
  }

  void _disposeScene() {
    _background?.dispose();
    _background = null;
    _splatterPicture?.dispose();
    _splatterPicture = null;
  }

  void _onControllerEvent() {
    final controller = widget.controller;
    if (controller._pendingReset) {
      controller._pendingReset = false;
      _falling.clear();
      _landedThisSession.clear();
      _pendingFallOnDoneCallback = null;
    }
    if (controller._pendingGusts.isNotEmpty) {
      _gusts.addAll(controller._pendingGusts);
      controller._pendingGusts.clear();
    }
    final fallIndices = controller._pendingFallIndices;
    if (fallIndices != null) {
      controller._pendingFallIndices = null;
      final onDone = controller._pendingFallOnDone;
      controller._pendingFallOnDone = null;
      _beginFall(fallIndices, onDone);
    }
  }

  void _beginFall(List<int> leafIndices, VoidCallback? onDone) {
    const sweepDuration = 2.4;
    for (var i = 0; i < leafIndices.length; i++) {
      final delay = leafIndices.isEmpty
          ? 0.0
          : (i / leafIndices.length) * sweepDuration;
      _falling[leafIndices[i]] = _FallingLeaf(
        leafIndex: leafIndices[i],
        startDelay: delay,
      );
    }
    _pendingFallOnDoneCallback = onDone;
  }

  VoidCallback? _pendingFallOnDoneCallback;

  void _tick() {
    if (!mounted) return;
    final now = _clock.elapsedMicroseconds / 1e6;
    final dt = math.min(now - _lastTick, 0.1);
    _lastTick = now;
    _time = now;
    if (dt <= 0) return;

    for (final gust in _gusts) {
      gust._elapsed += dt;
    }
    _gusts.removeWhere((g) => g.isDone);

    if (_falling.isNotEmpty) {
      final done = <int>[];
      for (final leaf in _falling.values) {
        leaf.elapsed += dt;
        if (leaf.isDone) done.add(leaf.leafIndex);
      }
      for (final index in done) {
        _falling.remove(index);
        _landedThisSession.add(index);
      }
      if (_falling.isEmpty && _landedThisSession.isNotEmpty) {
        _pendingFallOnDoneCallback?.call();
        _pendingFallOnDoneCallback = null;
      }
    }

    setState(() {});
  }

  void _ensureAtlas(List<Color> colors) {
    if (_atlas != null && listEquals(_atlasColors, colors)) return;
    _atlas?.dispose();

    final designs = widget.geometry.leafDesigns;
    const cols = 4;
    final leafCellCount = designs.length * colors.length;
    final rows = (leafCellCount / cols).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final cellRects = <Rect>[];

    for (var d = 0; d < designs.length; d++) {
      for (var c = 0; c < colors.length; c++) {
        final cellIndex = d * colors.length + c;
        final col = cellIndex % cols;
        final row = cellIndex ~/ cols;
        final rect = Rect.fromLTWH(
          col * _spriteExtent,
          row * _spriteExtent,
          _spriteExtent,
          _spriteExtent,
        );
        cellRects.add(rect);
        canvas.save();
        canvas.translate(rect.left, rect.top);
        canvas.saveLayer(
          Rect.fromLTWH(0, 0, _spriteExtent, _spriteExtent),
          Paint()..color = Color.fromARGB(_leafAlpha, 255, 255, 255),
        );
        paintLeaf(canvas, designs[d], Rect.fromLTWH(0, 0, _spriteExtent, _spriteExtent), colors[c]);
        canvas.restore();
        canvas.restore();
      }
    }

    final atlasImage = recorder.endRecording().toImageSync(
      (cols * _spriteExtent).toInt(),
      (rows * _spriteExtent).toInt(),
    );

    _atlas = atlasImage;
    _atlasColors = colors;
    _leafCellRects = cellRects;
  }

  /// A small tile of scattered specks, repeated across the canvas. Paper
  /// fibre is the single strongest cue that a painting was made with water
  /// and pigment rather than vectors, so it goes over everything.
  void _ensureGrain(Color ink) {
    if (_grain != null && _grainInk == ink) return;
    _grain?.dispose();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rand = math.Random(917);
    final paint = Paint();
    for (var i = 0; i < 2400; i++) {
      paint.color = ink.withValues(alpha: 0.03 + rand.nextDouble() * 0.06);
      canvas.drawCircle(
        Offset(
          rand.nextDouble() * _grainExtent,
          rand.nextDouble() * _grainExtent,
        ),
        0.35 + rand.nextDouble() * 0.75,
        paint,
      );
    }

    _grain = recorder.endRecording().toImageSync(_grainExtent, _grainExtent);
    _grainInk = ink;
    _grainShader = ui.ImageShader(
      _grain!,
      TileMode.repeated,
      TileMode.repeated,
      Matrix4.identity().storage,
    );
  }

  void _ensureScene(Size size, List<Color> palette, double dpr) {
    final scale = math.min(dpr, _maxBackgroundScale);
    final valid = _background != null &&
        _sceneSize == size &&
        _sceneDpr == scale &&
        listEquals(_sceneColors, palette) &&
        _sceneInk == widget.inkColor &&
        _sceneGround == widget.groundColor;
    if (valid) return;

    _disposeScene();

    final pixelSize = Size(size.width * scale, size.height * scale);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & pixelSize);
    canvas.scale(scale);
    _paintGround(canvas, size);
    // Order matters: the mid-tone wash goes down first, then the woody
    // structure over it, so twigs read as dark lines through the blossom. The
    // stipple lands across both, and is the only part still painted live.
    for (var i = 0; i < widget.geometry.clumps.length; i++) {
      _paintClump(canvas, size, i, palette);
    }
    _paintWood(canvas, size);
    final picture = recorder.endRecording();
    _background = picture.toImageSync(
      math.max(1, pixelSize.width.ceil()),
      math.max(1, pixelSize.height.ceil()),
    );
    picture.dispose();

    // Splatter sits over the stipple so it cannot join the background, but it
    // is a few hundred flat circles with no blur or layer — cheap to replay.
    final splatterRecorder = ui.PictureRecorder();
    _paintSplatter(Canvas(splatterRecorder, Offset.zero & size), size, palette);
    _splatterPicture = splatterRecorder.endRecording();

    _sceneSize = size;
    _sceneDpr = scale;
    _sceneColors = palette;
    _sceneInk = widget.inkColor;
    _sceneGround = widget.groundColor;
  }

  /// A soft pool of shadow smeared under the tree — no horizon, no edge, just
  /// damp pigment on the paper, as in the reference.
  void _paintGround(Canvas canvas, Size size) {
    final ground = widget.groundColor;
    final gy = widget.geometry.groundY * size.height;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.485, gy + size.height * 0.008),
        width: size.width * 0.46,
        height: size.height * 0.055,
      ),
      Paint()
        ..color = ground.withValues(alpha: 0.16)
        ..maskFilter =
            ui.MaskFilter.blur(ui.BlurStyle.normal, size.height * 0.022),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.52, gy + size.height * 0.014),
        width: size.width * 0.24,
        height: size.height * 0.030,
      ),
      Paint()
        ..color = ground.withValues(alpha: 0.20)
        ..maskFilter =
            ui.MaskFilter.blur(ui.BlurStyle.normal, size.height * 0.010),
    );
  }

  /// Trunk, roots, branches and twigs, painted the way an ink-and-water wash
  /// builds up — a soft bled undertone, a translucent body, a darker pool
  /// down one side, a soft (never crisp) rim, and granulation inside.
  void _paintWood(Canvas canvas, Size size) {
    final ink = widget.inkColor;
    final wood = Path();
    for (final limb in widget.geometry.limbs) {
      wood.addPath(_limbRibbon(limb, size), Offset.zero);
    }

    final bounds = wood.getBounds();
    final blur = size.shortestSide * 0.005;

    canvas.drawPath(
      wood,
      Paint()
        ..color = ink.withValues(alpha: 0.14)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur * 1.8),
    );

    canvas.drawPath(
      wood,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, bounds.top),
          Offset(0, bounds.bottom),
          [
            ink.withValues(alpha: 0.52),
            ink.withValues(alpha: 0.72),
            ink.withValues(alpha: 0.86),
          ],
          const [0.0, 0.55, 1.0],
        ),
    );

    canvas.save();
    canvas.clipPath(wood);
    // Pigment settling along one side of every limb, the way water pulls it
    // to the low edge of a stroke.
    canvas.drawPath(
      wood.shift(Offset(size.shortestSide * 0.0035, 0)),
      Paint()
        ..color = ink.withValues(alpha: 0.26)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur * 0.8),
    );
    final rand = math.Random(5501);
    final speckPaint = Paint();
    for (var i = 0; i < 220; i++) {
      speckPaint.color = ink.withValues(alpha: 0.05 + rand.nextDouble() * 0.10);
      canvas.drawCircle(
        Offset(
          bounds.left + rand.nextDouble() * bounds.width,
          bounds.top + rand.nextDouble() * bounds.height,
        ),
        size.shortestSide * (0.0008 + rand.nextDouble() * 0.0016),
        speckPaint,
      );
    }
    canvas.restore();

    canvas.drawPath(
      wood,
      Paint()
        ..color = ink.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.0016
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur * 0.30),
    );
  }

  /// Pigment flicked off the brush around the crown.
  void _paintSplatter(Canvas canvas, Size size, List<Color> palette) {
    final paint = Paint();
    for (final speck in widget.geometry.splatter) {
      paint.color = palette[speck.colorIndex.clamp(0, palette.length - 1)]
          .withValues(alpha: 0.55);
      canvas.drawCircle(
        Offset(speck.position.dx * size.width, speck.position.dy * size.height),
        speck.size * size.shortestSide,
        paint,
      );
    }
  }

  /// The faint mid-tone wash a clump sits on. Deliberately weak: in this
  /// technique the crown's colour comes from the stipple drawn over it, and
  /// the wash only stops bare paper reading through the densest areas.
  void _paintClump(Canvas canvas, Size size, int clumpIndex, List<Color> palette) {
    final clump = widget.geometry.clumps[clumpIndex];
    final cx = clump.center.dx * size.width;
    final cy = clump.center.dy * size.height;
    final rx = clump.radiusX * size.width;
    final ry = clump.radiusY * size.height;
    final cullRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: rx * 4,
      height: ry * 4,
    );

    canvas.saveLayer(cullRect, Paint());

    for (final blob in widget.geometry.blobs) {
      if (blob.clumpIndex != clumpIndex) continue;
      final path = _blobPath(blob, size);
      final color = palette[blob.colorIndex.clamp(0, palette.length - 1)];
      final radius =
          (blob.radiusX * size.width + blob.radiusY * size.height) / 2;

      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.045 + blob.depth * 0.030)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, radius * 0.30),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.070 + blob.depth * 0.040)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, radius * 0.12),
      );
    }

    // Light from the upper left, shadow gathering underneath — applied only
    // where the wash exists, so nothing bleeds onto bare paper.
    canvas.drawRect(
      cullRect,
      Paint()
        ..blendMode = BlendMode.srcATop
        ..shader = ui.Gradient.radial(
          Offset(cx - rx * 0.35, cy - ry * 0.55),
          math.max(rx, ry) * 2.1,
          [
            const Color(0xFFFFFFFF).withValues(alpha: 0.14),
            const Color(0xFFFFFFFF).withValues(alpha: 0.0),
            widget.inkColor.withValues(alpha: 0.12),
          ],
          const [0.0, 0.42, 1.0],
        ),
    );

    canvas.restore();
  }

  /// A closed blot outline: an ellipse whose radius is perturbed by three
  /// harmonics, smoothed through the midpoints of the sampled ring.
  Path _blobPath(CanopyBlob blob, Size size) {
    final cx = blob.center.dx * size.width;
    final cy = blob.center.dy * size.height;
    final rx = blob.radiusX * size.width;
    final ry = blob.radiusY * size.height;
    const steps = 26;

    final points = <Offset>[];
    for (var i = 0; i < steps; i++) {
      final a = i / steps * math.pi * 2;
      final k = 1 +
          blob.wobbleAmount *
              (0.55 * math.sin(3 * a + blob.wobblePhases[0]) +
                  0.30 * math.sin(5 * a + blob.wobblePhases[1]) +
                  0.18 * math.sin(7 * a + blob.wobblePhases[2]));
      final angle = a + blob.rotation;
      points.add(
        Offset(cx + math.cos(angle) * rx * k, cy + math.sin(angle) * ry * k),
      );
    }

    Offset mid(Offset a, Offset b) => Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

    final start = mid(points.last, points.first);
    final path = Path()..moveTo(start.dx, start.dy);
    for (var i = 0; i < steps; i++) {
      final m = mid(points[i], points[(i + 1) % steps]);
      path.quadraticBezierTo(points[i].dx, points[i].dy, m.dx, m.dy);
    }
    return path..close();
  }

  /// A limb as a filled ribbon that tapers from base to tip, sampled along
  /// its curve and offset along the normal at each step.
  Path _limbRibbon(TreeLimb limb, Size size) {
    Offset toPixels(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

    final a = toPixels(limb.start);
    final b = toPixels(limb.control);
    final c = toPixels(limb.end);
    final startHalf = limb.startWidth * size.shortestSide / 2;
    final endHalf = limb.endWidth * size.shortestSide / 2;
    const steps = 22;

    final left = <Offset>[];
    final right = <Offset>[];
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final p = quadPointAt(a, b, c, t);
      final tangent = quadTangentAt(a, b, c, t);
      final length = tangent.distance;
      final normal = length == 0
          ? Offset.zero
          : Offset(-tangent.dy / length, tangent.dx / length);
      // Tapering faster than linearly keeps limbs stout at the base and fine
      // at the tip, the way wood actually thins. The floor keeps the finest
      // twigs from thinning into invisible slivers.
      final taper = math.pow(1 - t, 1.45).toDouble();
      final half =
          math.max(endHalf + (startHalf - endHalf) * taper, 0.45);
      left.add(p + normal * half);
      right.add(p - normal * half);
    }

    final path = Path()..moveTo(left.first.dx, left.first.dy);
    for (final p in left.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    for (final p in right.reversed) {
      path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();

        final palette = buildTonePalette(widget.leafColors);
        _ensureAtlas(palette);
        _ensureGrain(widget.inkColor);
        _ensureScene(size, palette, MediaQuery.devicePixelRatioOf(context));

        final atlas = _atlas;
        final background = _background;
        final splatter = _splatterPicture;
        final grainShader = _grainShader;
        if (atlas == null ||
            background == null ||
            splatter == null ||
            grainShader == null) {
          return const SizedBox.shrink();
        }

        return RepaintBoundary(
          child: CustomPaint(
            size: size,
            isComplex: true,
            willChange: true,
            painter: _LifeTreePainter(
              geometry: widget.geometry,
              background: background,
              splatter: splatter,
              grainShader: grainShader,
              atlas: atlas,
              leafCellRects: _leafCellRects,
              rstBuffer: _rstBuffer,
              rectBuffer: _rectBuffer,
              restPositions: _restPositions,
              restRotations: _restRotations,
              colorCount: palette.length,
              time: _time,
              // Passed live rather than copied: the painter only reads them,
              // and snapshotting the fall map rebuilt a 4160-entry map every
              // frame for the whole opening animation.
              gusts: _gusts,
              falling: _falling,
              groundedLeafIndices: widget.groundedLeafIndices,
              landedThisSession: _landedThisSession,
            ),
          ),
        );
      },
    );
  }
}

/// A clump's live sway, resolved once per frame and then applied to both its
/// wash layer and every stipple speck hanging in it.
class _ClumpTransform {
  _ClumpTransform(this.cos, this.sin, this.pivot, this.roll);

  final double cos;
  final double sin;
  final Offset pivot;
  final double roll;

  Offset apply(Offset p) {
    final dx = p.dx - pivot.dx;
    final dy = p.dy - pivot.dy;
    return Offset(
      dx * cos - dy * sin + pivot.dx,
      dx * sin + dy * cos + pivot.dy,
    );
  }
}

class _LifeTreePainter extends CustomPainter {
  _LifeTreePainter({
    required this.geometry,
    required this.background,
    required this.splatter,
    required this.grainShader,
    required this.atlas,
    required this.leafCellRects,
    required this.rstBuffer,
    required this.rectBuffer,
    required this.restPositions,
    required this.restRotations,
    required this.colorCount,
    required this.time,
    required this.gusts,
    required this.falling,
    required this.groundedLeafIndices,
    required this.landedThisSession,
  });

  static const _spriteExtent = 96.0;

  final LifeTreeGeometry geometry;

  /// Ground, canopy wash and wood, pre-rasterized at canvas size.
  final ui.Image background;
  final ui.Picture splatter;
  final ui.ImageShader grainShader;
  final ui.Image atlas;
  final List<Rect> leafCellRects;
  final Float32List rstBuffer;
  final Float32List rectBuffer;
  final List<Offset> restPositions;
  final Float32List restRotations;
  final int colorCount;
  final double time;
  final List<_LeafShudder> gusts;
  final Map<int, _FallingLeaf> falling;
  final Set<int> groundedLeafIndices;
  final Set<int> landedThisSession;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final breathe = 1 + math.sin(time * 0.34) * 0.004;
    final pivot = Offset(
      geometry.trunkTop.dx * size.width,
      geometry.trunkTop.dy * size.height,
    );
    final transforms = _resolveClumpTransforms(size);

    canvas.drawImageRect(
      background,
      Offset.zero &
          Size(background.width.toDouble(), background.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );

    // The wash underneath no longer sways with its clump. At a peak roll of
    // about a degree on pigment this faint, the motion was never visible —
    // and holding it still is what lets the whole background be one texture.
    // The stipple over it still sways and breathes, which is the canopy the
    // eye actually tracks.
    _paintStipple(canvas, size, transforms, pivot, breathe);
    canvas.drawPicture(splatter);

    canvas.drawRect(Offset.zero & size, Paint()..shader = grainShader);
  }

  /// The canopy breathes as one: every clump shares a slow global scale about
  /// the trunk's top, with only a fractional-degree roll of its own about the
  /// branch that holds it. A gust adds a brief localized shiver.
  List<_ClumpTransform> _resolveClumpTransforms(Size size) {
    return [
      for (final clump in geometry.clumps)
        () {
          var shiver = 0.0;
          for (final gust in gusts) {
            shiver += gust.extraAt(clump.center);
          }
          final roll = math.sin(time * 0.34 + clump.swayPhase) * 0.008 +
              math.sin(time * 7.5 + clump.swayPhase) * 0.02 * shiver;
          return _ClumpTransform(
            math.cos(roll),
            math.sin(roll),
            Offset(clump.pivot.dx * size.width, clump.pivot.dy * size.height),
            roll,
          );
        }(),
    ];
  }

  /// Every one of the 4160 weeks, as one speck of blossom. Attached specks
  /// ride their clump's sway; detached ones fall free, and a landed one stays
  /// where it settled — the crown genuinely thins as weeks are spent.
  void _paintStipple(
    Canvas canvas,
    Size size,
    List<_ClumpTransform> transforms,
    Offset pivot,
    double breathe,
  ) {
    final leaves = geometry.leaves;
    const anchor = _spriteExtent / 2;

    for (var i = 0; i < leaves.length; i++) {
      final leaf = leaves[i];
      final fallingLeaf = falling[i];
      final isGrounded =
          groundedLeafIndices.contains(i) || landedThisSession.contains(i);

      double x;
      double y;
      double angle;

      if (isGrounded && fallingLeaf == null) {
        final at = restPositions[i];
        x = at.dx * size.width;
        y = at.dy * size.height;
        angle = restRotations[i];
      } else if (fallingLeaf != null && fallingLeaf.hasStarted) {
        final p = fallingLeaf.progress;
        final t = Curves.easeIn.transform(p);
        final ground = restPositions[i];
        final drift =
            math.sin(p * math.pi * 2.3 + leaf.swayPhase) * 0.024 * (1 - t);
        x = (leaf.position.dx + (ground.dx - leaf.position.dx) * t + drift) *
            size.width;
        y = (leaf.position.dy + (ground.dy - leaf.position.dy) * t) * size.height;
        angle = leaf.baseAngle +
            (restRotations[i] - leaf.baseAngle) * t +
            math.sin(p * 5.5 + leaf.swayPhase) * 0.6 * (1 - t);
      } else {
        // Still on the tree: sways with its clump, breathes with the crown.
        final transform = transforms[leaf.clumpIndex];
        final swayed = transform.apply(
          Offset(leaf.position.dx * size.width, leaf.position.dy * size.height),
        );
        x = pivot.dx + (swayed.dx - pivot.dx) * breathe;
        y = pivot.dy + (swayed.dy - pivot.dy) * breathe;
        angle = leaf.baseAngle + transform.roll;
      }

      final scale = leaf.size * size.shortestSide * 2 / _spriteExtent;
      final scos = math.cos(angle) * scale;
      final ssin = math.sin(angle) * scale;

      final t = i * 4;
      rstBuffer[t] = scos;
      rstBuffer[t + 1] = ssin;
      rstBuffer[t + 2] = x - (scos * anchor - ssin * anchor);
      rstBuffer[t + 3] = y - (ssin * anchor + scos * anchor);

      final cellIndex =
          leaf.designIndex * colorCount + leaf.colorIndex.clamp(0, colorCount - 1);
      final cell = leafCellRects[cellIndex.clamp(0, leafCellRects.length - 1)];
      rectBuffer[t] = cell.left;
      rectBuffer[t + 1] = cell.top;
      rectBuffer[t + 2] = cell.right;
      rectBuffer[t + 3] = cell.bottom;
    }

    canvas.drawRawAtlas(
      atlas,
      rstBuffer,
      rectBuffer,
      null,
      null,
      null,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _LifeTreePainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.gusts.length != gusts.length ||
        oldDelegate.falling.length != falling.length ||
        oldDelegate.landedThisSession.length != landedThisSession.length ||
        !identical(oldDelegate.background, background) ||
        !identical(oldDelegate.atlas, atlas);
  }
}

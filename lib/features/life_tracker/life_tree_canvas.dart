import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/leaf_shapes.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// A localized shudder applied to nearby foliage — the "gust" a stat popup
/// kicks up when it opens.
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

/// One leaf currently animating from its canopy anchor down to the ground, as
/// part of the first-run opening animation.
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

/// Standard-normal sample via Box-Muller, using [r] as the entropy source.
double _gaussian(math.Random r) {
  final u1 = 1.0 - r.nextDouble(); // (0, 1], never log(0)
  final u2 = r.nextDouble();
  return math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

/// How tightly the fallen leaves cluster around [LifeTreeGeometry.trunkBase]
/// — wide enough that the tails reach both edges of the screen, while the
/// bell curve's own shape keeps the pile peaked at the trunk rather than
/// smearing evenly across the width.
const _groundPileStdDev = 0.22;

/// Deterministic landing spot + rest rotation for a fallen leaf, keyed only by
/// its index — so grounded leaves never need their own persisted position,
/// just the fact that they landed (see [LifeTreeCanvasController]).
///
/// A true bell curve centered under the trunk's base, rather than a uniform
/// scatter or an independent per-leaf position — real fallen petals mound up
/// where the tree actually stands, thinning out steadily toward the edges,
/// which needs an actual peak in the distribution rather than a flat band.
/// Settles onto the ground line itself ([LifeTreeGeometry.groundY]) so it
/// always matches wherever the tree currently sits, instead of a hardcoded
/// band that silently goes stale whenever the tree is repositioned.
Offset groundPositionFor(int leafIndex, LifeTreeGeometry geometry) {
  final r = math.Random(leafIndex * 7919 + 13);

  final x = (geometry.trunkBase.dx + _gaussian(r) * _groundPileStdDev)
      .clamp(0.04, 0.96);

  // A gentle per-position undulation keeps the pile from reading as a dead
  // flat line, echoing the grass's own irregular baseline without needing to
  // sample it directly.
  final undulation = math.sin(x * 23.0 + leafIndex * 0.7) * 0.006;
  final y = geometry.groundY + 0.010 + r.nextDouble() * 0.034 + undulation;

  return Offset(x, y);
}

double groundRotationFor(int leafIndex) {
  return math.Random(leafIndex * 104729 + 31).nextDouble() * math.pi * 2;
}

/// Diameter, in logical pixels, a leaf is drawn at once it detaches from the
/// canopy and starts falling — matching [PetalFieldParams]'s background
/// petals (`5.0 + rand * 7.0` half-width, i.e. 10-24px across) rather than the
/// much smaller stipple grain it reads as while still on the tree.
double fallenLeafDiameterFor(int leafIndex) {
  final r = math.Random(leafIndex * 60013 + 7);
  return 10.0 + r.nextDouble() * 14.0;
}

/// Imperative handle for triggering the gust shudder and the first-run opening
/// fall.
class LifeTreeCanvasController extends ChangeNotifier {
  final List<_LeafShudder> _pendingGusts = [];
  List<int>? _pendingFallIndices;
  VoidCallback? _pendingFallOnDone;

  /// Shudders the foliage near [normalizedPosition] — called when a popup
  /// opens, so the tree visibly reacts.
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
/// colour. The canopy is built by layering translucent pools of these in
/// multiply, and a single flat pink stacks into a flat mass — the depth in the
/// reference painting comes entirely from mixing tints and deep accents.
List<Color> buildTonePalette(List<Color> base) {
  final palette = <Color>[];
  for (var i = 0; i < 4; i++) {
    final color = base[i % base.length];
    palette
      ..add(Color.lerp(color, const Color(0xFFFDEEF1), 0.30)!)
      ..add(color)
      ..add(Color.lerp(color, const Color(0xFFC85466), 0.35)!);
  }
  return palette;
}

class LifeTreeCanvas extends StatefulWidget {
  const LifeTreeCanvas({
    super.key,
    required this.geometry,
    required this.leafColors,
    required this.inkColor,
    required this.paperColor,
    required this.grassColor,
    required this.groundedLeafIndices,
    required this.controller,
    required this.accentColor,
    this.hovered = false,
    this.showDebugColors = false,
  });

  final LifeTreeGeometry geometry;

  /// Index 0 is the primary leaf tint, 1-3 are minor tints. Expanded into
  /// tones by [buildTonePalette] before anything is painted.
  final List<Color> leafColors;

  /// Pigment the woody parts and the paper grain are painted in.
  final Color inkColor;

  /// The paper itself. Every wash is multiplied over this, so it has to be
  /// painted rather than left to the scaffold behind — a transparent canvas
  /// would give multiply nothing to darken.
  final Color paperColor;

  final Color grassColor;

  /// Leaves already permanently grounded from a previous run this session.
  final Set<int> groundedLeafIndices;

  /// Tint for the whole-tree hover glow — see [hovered].
  final Color accentColor;

  /// Whether the pointer is currently over the tree (outside the individual
  /// stat labels). Eased into a soft glow along the trunk, branches, roots
  /// and canopy rather than snapping on, so it reads as the tree itself
  /// responding rather than a UI hover state.
  final bool hovered;
  final LifeTreeCanvasController controller;

  /// Highlight each segment of the tree trunk, roots, and branches in
  /// distinct glowing colors and labels for manual debugging.
  final bool showDebugColors;

  @override
  State<LifeTreeCanvas> createState() => _LifeTreeCanvasState();
}

class _LifeTreeCanvasState extends State<LifeTreeCanvas> {
  static const _frameInterval = Duration(milliseconds: 16);
  static const _spriteExtent = 96.0;

  /// Alpha baked into every petal sprite (0-255). Kept light so stipple adds
  /// subtle grain over the wash rather than darkening it into a muddy blob.
  static const _leafAlpha = 35;

  /// Alpha baked into a leaf once it's landed and settled on the ground —
  /// 70% opacity per user request, well above the on-tree stipple so fallen
  /// leaves read clearly against the grass instead of staying a faint grain.
  static const _landedLeafAlpha = 179;

  static const _grainExtent = 128;

  /// How finely the canopy's shedding is quantized. Each new step re-bakes the
  /// background, so this trades smoothness of the thinning against the number
  /// of re-bakes during the opening fall.
  static const _sweepSteps = 14;
  static const _shedSteps = 24;

  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  double _time = 0;
  double _lastTick = 0;
  var _tickerModeEnabled = true;

  /// Eased 0-1 strength of the whole-tree hover glow, chasing [LifeTreeCanvas.
  /// hovered] every tick rather than snapping, so the glow fades in and out.
  double _hoverGlow = 0;

  final List<_LeafShudder> _gusts = [];
  final Map<int, _FallingLeaf> _falling = {};
  final Set<int> _landedThisSession = {};

  ui.Image? _atlas;
  List<Color>? _atlasColors;
  late List<Rect> _leafCellRects;

  // A second atlas of the same sprites baked at _landedLeafAlpha, used only
  // for leaves that have settled on the ground.
  ui.Image? _landedAtlas;
  List<Color>? _landedAtlasColors;

  ui.Image? _grain;
  Color? _grainInk;
  ui.ImageShader? _grainShader;

  // Every leaf is drawn every frame — attached, falling or landed — so the
  // atlas buffers are allocated once and refilled in place rather than
  // rebuilding 4160 transform objects sixty times a second. Split into a
  // still-on-tree/falling pair and a landed pair, one leaf ever going into
  // only one of the two on a given frame.
  late final Float32List _rstBuffer =
      Float32List(widget.geometry.leaves.length * 4);
  late final Float32List _landedRstBuffer =
      Float32List(widget.geometry.leaves.length * 4);
  late final Float32List _landedRectBuffer =
      Float32List(widget.geometry.leaves.length * 4);
  late final Float32List _rectBuffer =
      Float32List(widget.geometry.leaves.length * 4);

  // Resting places, resolved once. These are derived from the leaf index
  // alone, but deriving them seeds a Random per leaf — and every grounded or
  // falling leaf needs both of them on every frame.
  late final List<Offset> _restPositions = [
    for (var i = 0; i < widget.geometry.leaves.length; i++)
      groundPositionFor(i, widget.geometry),
  ];
  late final Float32List _restRotations = Float32List.fromList([
    for (var i = 0; i < widget.geometry.leaves.length; i++) groundRotationFor(i),
  ]);
  late final Float32List _fallenDiameters = Float32List.fromList([
    for (var i = 0; i < widget.geometry.leaves.length; i++) fallenLeafDiameterFor(i),
  ]);

  // The woody skeleton and the grass never change with the shed/sweep level
  // (only the canopy wash does), so they're rasterized once into their own
  // layer and reused across every re-bake of the fall — recomputing their
  // path unions and dry-brush streaks tens of times over one fall animation
  // was the main cost behind its frame drops.
  ui.Image? _staticLayer;

  // Paper, 250-odd canopy washes, the whole woody skeleton, the grass and the
  // figure are all static for a given shed level. A ui.Picture is a display
  // list, not a texture, so replaying one re-runs every path fill inside it on
  // every frame — rasterize it once instead and blit the result.
  ui.Image? _background;
  Size? _sceneSize;
  double? _sceneDpr;
  List<Color>? _sceneColors;
  Color? _sceneInk;
  Color? _scenePaper;
  Color? _sceneGrass;
  double? _sceneShed;
  double? _sceneSweep;
  bool? _sceneShowDebugColors;

  /// Guards against a re-bake that was kicked off before a resize (or before
  /// disposal) landing afterwards and replacing a newer background.
  int _bakeGeneration = 0;

  /// Ceiling on the backing texture's resolution. The background is soft
  /// washes and flat ink, so there is nothing to gain from rendering it beyond
  /// this, and the memory saving on a hidpi display is large.
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
    _bakeGeneration++;
    _atlas?.dispose();
    _landedAtlas?.dispose();
    _grain?.dispose();
    _disposeScene();
    super.dispose();
  }

  void _disposeScene() {
    _background?.dispose();
    _background = null;
    _staticLayer?.dispose();
    _staticLayer = null;
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

    final glowTarget = widget.hovered ? 1.0 : 0.0;
    _hoverGlow += (glowTarget - _hoverGlow) * (1 - math.exp(-6.0 * dt));
    if ((_hoverGlow - glowTarget).abs() < 0.001) _hoverGlow = glowTarget;

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

  /// How much of the canopy has washed out, and how far the wave of thinning
  /// has travelled around the crown. The fall drops leaves in order of their
  /// angle, so following the landed count with the wash keeps the pigment
  /// disappearing just behind the petals that left it.
  ({double shed, double sweep}) _erosion() {
    final total = widget.geometry.leaves.length;
    if (total == 0) return (shed: 0.0, sweep: 1.0);
    final inFlight = _falling.length + _landedThisSession.length;
    final shed =
        math.max(widget.groundedLeafIndices.length, inFlight) / total;
    final sweep = _falling.isEmpty
        ? 1.0
        : _landedThisSession.length / math.max(1, inFlight);
    return (
      shed: (shed * _shedSteps).round() / _shedSteps,
      sweep: (sweep * _sweepSteps).round() / _sweepSteps,
    );
  }

  void _ensureAtlas(List<Color> colors) {
    if (_atlas != null && listEquals(_atlasColors, colors)) return;
    _atlas?.dispose();
    final built = _buildAtlas(colors, _leafAlpha);
    _atlas = built.image;
    _atlasColors = colors;
    _leafCellRects = built.cellRects;
  }

  void _ensureLandedAtlas(List<Color> colors) {
    if (_landedAtlas != null && listEquals(_landedAtlasColors, colors)) return;
    _landedAtlas?.dispose();
    _landedAtlas = _buildAtlas(colors, _landedLeafAlpha).image;
    _landedAtlasColors = colors;
  }

  ({ui.Image image, List<Rect> cellRects}) _buildAtlas(
    List<Color> colors,
    int alpha,
  ) {
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
          Paint()..color = Color.fromARGB(alpha, 255, 255, 255),
        );
        _paintBloom(canvas, designs[d], Rect.fromLTWH(0, 0, _spriteExtent, _spriteExtent), colors[c]);
        canvas.restore();
        canvas.restore();
      }
    }

    final image = recorder.endRecording().toImageSync(
      (cols * _spriteExtent).toInt(),
      (rows * _spriteExtent).toInt(),
    );

    return (image: image, cellRects: cellRects);
  }

  /// Draws one bloom sprite as a flat fill with a slightly deeper rim, kept
  /// separate from [paintLeaf] so the tree's stipple doesn't inherit the
  /// gradient/blur treatment shared with the dream journal and the app-wide
  /// falling-petal background.
  void _paintBloom(Canvas canvas, LeafDesign design, Rect rect, Color color) {
    final path = design.pathBuilder(rect);
    final borderColor = Color.lerp(color, const Color(0xFF000000), 0.30)!;
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.50));
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor.withValues(alpha: 0.60)
        ..style = PaintingStyle.stroke
        ..strokeWidth = rect.shortestSide * 0.035
        ..isAntiAlias = true,
    );
  }

  /// A small tile of scattered specks, repeated across the canvas. Paper fibre
  /// is the single strongest cue that a painting was made with water and
  /// pigment rather than vectors, so it goes over everything.
  void _ensureGrain(Color ink) {
    if (_grain != null && _grainInk == ink) return;
    _grain?.dispose();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rand = math.Random(917);
    final paint = Paint();
    for (var i = 0; i < 2400; i++) {
      paint.color = ink.withValues(alpha: 0.018 + rand.nextDouble() * 0.038);
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

  /// The woody skeleton and grass, which don't depend on the shed/sweep level
  /// (or the leaf palette) at all — see [_staticLayer].
  ui.Picture _recordStaticLayer(Size size, double scale) {
    final pixelSize = Size(size.width * scale, size.height * scale);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & pixelSize);
    canvas.scale(scale);

    canvas.drawColor(const Color(0x00000000), BlendMode.src);

    _paintWood(canvas, size);
    _paintGrass(canvas, size);
    return recorder.endRecording();
  }

  ui.Picture _recordBackground(Size size, List<Color> palette, double scale,
      double shed, double sweep, ui.Image staticLayer) {
    final pixelSize = Size(size.width * scale, size.height * scale);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & pixelSize);

    canvas.drawImageRect(
      staticLayer,
      Offset.zero &
          Size(staticLayer.width.toDouble(), staticLayer.height.toDouble()),
      Offset.zero & pixelSize,
      Paint()..filterQuality = FilterQuality.low,
    );

    canvas.scale(scale);
    _paintCrown(canvas, size, palette, shed, sweep);
    return recorder.endRecording();
  }

  ui.Image _rasterize(ui.Picture picture, Size size, double scale) {
    final image = picture.toImageSync(
      math.max(1, (size.width * scale).ceil()),
      math.max(1, (size.height * scale).ceil()),
    );
    picture.dispose();
    return image;
  }

  void _ensureScene(Size size, List<Color> palette, double dpr) {
    final scale = math.min(dpr, _maxBackgroundScale);
    final erosion = _erosion();
    final layoutValid = _background != null &&
        _staticLayer != null &&
        _sceneSize == size &&
        _sceneDpr == scale &&
        listEquals(_sceneColors, palette) &&
        _sceneInk == widget.inkColor &&
        _scenePaper == widget.paperColor &&
        _sceneGrass == widget.grassColor &&
        _sceneShowDebugColors == widget.showDebugColors;

    if (layoutValid) {
      if (_sceneShed == erosion.shed && _sceneSweep == erosion.sweep) return;
      // Only the canopy's thinning changed. Re-bake off the frame and keep
      // showing the current background until the new one is ready — doing this
      // synchronously drops a frame every step of the opening animation. The
      // static wood+grass layer is reused as-is since neither depends on
      // shed/sweep.
      _sceneShed = erosion.shed;
      _sceneSweep = erosion.sweep;
      _rebakeAsync(size, palette, scale, erosion.shed, erosion.sweep, _staticLayer!);
      return;
    }

    _disposeScene();
    _bakeGeneration++;

    final staticLayer = _rasterize(_recordStaticLayer(size, scale), size, scale);
    _staticLayer = staticLayer;

    _background = _rasterize(
      _recordBackground(size, palette, scale, erosion.shed, erosion.sweep, staticLayer),
      size,
      scale,
    );

    _sceneSize = size;
    _sceneDpr = scale;
    _sceneColors = palette;
    _sceneInk = widget.inkColor;
    _scenePaper = widget.paperColor;
    _sceneGrass = widget.grassColor;
    _sceneShed = erosion.shed;
    _sceneSweep = erosion.sweep;
    _sceneShowDebugColors = widget.showDebugColors;
  }

  Future<void> _rebakeAsync(Size size, List<Color> palette, double scale,
      double shed, double sweep, ui.Image staticLayer) async {
    final generation = ++_bakeGeneration;
    final picture = _recordBackground(size, palette, scale, shed, sweep, staticLayer);
    final ui.Image image;
    try {
      image = await picture.toImage(
        math.max(1, (size.width * scale).ceil()),
        math.max(1, (size.height * scale).ceil()),
      );
    } catch (_) {
      // Nothing here is recoverable and nothing awaits this, so a failed
      // re-bake just leaves the previous canopy on screen rather than taking
      // the page down with an unhandled async error.
      picture.dispose();
      return;
    }
    picture.dispose();
    if (!mounted || generation != _bakeGeneration) {
      image.dispose();
      return;
    }
    _background?.dispose();
    _background = image;
    setState(() {});
  }

  /// Crosshair grid ticks scattered across the off-white paper stock, matching
  /// the reference background texture 1:1.
  // ignore: unused_element
  void _paintGridTicks(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = widget.inkColor.withValues(alpha: 0.12)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    const step = 48.0;
    const arm = 3.0;

    for (var x = step / 2; x < size.width; x += step) {
      for (var y = step / 2; y < size.height; y += step) {
        canvas.drawLine(Offset(x - arm, y), Offset(x + arm, y), paint);
        canvas.drawLine(Offset(x, y - arm), Offset(x, y + arm), paint);
      }
    }
  }

  /// The canopy: pools of pigment stacked in multiply with hard, lobed edges
  /// and a darker rim where the water dried. No blur anywhere — a blurred
  /// blossom reads as airbrush, and the crisp cauliflower edge is the entire
  /// difference between this and a gradient.
  void _paintCrown(
    Canvas canvas,
    Size size,
    List<Color> palette,
    double shed,
    double sweep,
  ) {
    final fade = 1.0 - 0.40 * shed;
    if (fade <= 0) return;

    final rimWidth = size.shortestSide * 0.0012;
    for (final cell in widget.geometry.cells) {
      if (cell.shedOrder < shed && cell.angleRank <= sweep) continue;
      final path = _cellPath(cell, size);
      final color = palette[cell.colorIndex.clamp(0, palette.length - 1)];
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: (cell.alpha * fade * 1.45).clamp(0.0, 0.28)),
      );
      // Soft edge darkening
      canvas.drawPath(
        path,
        Paint()
          ..color = palette[((cell.colorIndex ~/ 3) * 3 + 2)
                  .clamp(0, palette.length - 1)]
              .withValues(alpha: (cell.alpha * fade * 0.5).clamp(0.0, 0.18))
          ..style = PaintingStyle.stroke
          ..strokeWidth = rimWidth,
      );
    }
  }

  /// Grass at the foot of the tree: soft pale sage watercolor wash mound with
  /// fine calligraphic blades.
  void _paintGrass(Canvas canvas, Size size) {
    final groundY = widget.geometry.groundY * size.height;
    // Pale sage watercolor ground wash mound. Overshoots the canvas on both
    // sides — an oval's own left/right extremes come to a point, so bounding
    // it exactly at the canvas edges would visibly taper the wash right where
    // it should instead read as running the full width; pushing those points
    // off-screen keeps only the oval's flatter middle in view.
    canvas.drawOval(
      Rect.fromLTRB(
        -size.width * 0.15,
        groundY - size.height * 0.035,
        size.width * 1.15,
        groundY + size.height * 0.045,
      ),
      Paint()
        ..color = widget.grassColor.withValues(alpha: 0.20)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, size.height * 0.025),
    );

    for (final tuft in widget.geometry.grass) {
      final rand = math.Random(tuft.seed);
      final baseX = tuft.base.dx * size.width;
      final baseY = tuft.base.dy * size.height;
      final w = tuft.width * size.width;
      final h = tuft.height * size.height;
      final color = Color.lerp(
        widget.grassColor,
        Color.lerp(widget.grassColor, const Color(0xFF4A583A), 0.20)!,
        tuft.toneMix,
      )!;

      // Soft wash base under tuft
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(baseX, baseY - h * 0.15),
          width: w * 1.4,
          height: h * 0.55,
        ),
        Paint()
          ..color = color.withValues(alpha: 0.12)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, h * 0.30),
      );

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < tuft.bladeCount; i++) {
        final spread = (rand.nextDouble() - 0.5) * w;
        final tall = h * (0.40 + rand.nextDouble() * 0.65);
        final lean = spread * 0.75 + (rand.nextDouble() - 0.5) * w * 0.4;
        paint
          ..color = color.withValues(alpha: 0.18 + rand.nextDouble() * 0.30)
          ..strokeWidth = size.shortestSide * (0.0006 + rand.nextDouble() * 0.0012);
        canvas.drawPath(
          Path()
            ..moveTo(baseX + spread * 0.35, baseY)
            ..quadraticBezierTo(
              baseX + spread * 0.7,
              baseY - tall * 0.55,
              baseX + lean,
              baseY - tall,
            ),
          paint,
        );
      }
    }
  }

  // Cache of the unioned trunk/root/branch silhouette, keyed by the size it
  // was built for. Rebuilding this is a real cost (path union + convex hulls
  // over ~26 limbs), so it's resolved once per size rather than on every
  // frame — needed by [_paintWood].
  Path? _cachedWoodPath;
  Size? _cachedWoodPathSize;

  Path _woodPathFor(Size size) {
    final cached = _cachedWoodPath;
    if (cached != null && _cachedWoodPathSize == size) return cached;

    final wood = buildTreeWoodPath(widget.geometry, size);
    _cachedWoodPath = wood;
    _cachedWoodPathSize = size;
    return wood;
  }

  // Same idea, but just the trunk and branches (no roots) — the hover
  // glow's own silhouette, since it only lights up over the same region the
  // bucket-list tap responds to (see the trunk-and-branches clip in
  // life_tracker_page.dart).
  Path? _cachedGlowPath;
  Size? _cachedGlowPathSize;

  Path _glowPathFor(Size size) {
    final cached = _cachedGlowPath;
    if (cached != null && _cachedGlowPathSize == size) return cached;

    final path = buildTrunkAndBranchesPath(widget.geometry, size);
    _cachedGlowPath = path;
    _cachedGlowPathSize = size;
    return path;
  }

  /// Trunk, roots, branches and twigs painted as Sumi-e calligraphic brushwork.
  void _paintWood(Canvas canvas, Size size) {
    if (widget.showDebugColors) {
      _paintWoodDebugColors(canvas, size);
      return;
    }

    final ink = widget.inkColor;
    final wood = _woodPathFor(size);

    final blur = size.shortestSide * 0.004;

    // Ink bleed into damp paper around stroke edges
    canvas.drawPath(
      wood,
      Paint()
        ..color = ink.withValues(alpha: 0.12)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur * 1.5),
    );

    // Exact 40% opacity for branches per user request
    canvas.drawPath(wood, Paint()..color = ink.withValues(alpha: 0.40));

    canvas.save();
    canvas.clipPath(wood);

    // Dry brush skipping streaks along the grain of the wood
    final rand = math.Random(5501);
    final streak = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final limb in widget.geometry.limbs) {
      final a = Offset(limb.start.dx * size.width, limb.start.dy * size.height);
      final b = Offset(limb.control.dx * size.width, limb.control.dy * size.height);
      final c = Offset(limb.end.dx * size.width, limb.end.dy * size.height);
      final half = limb.startWidth * size.shortestSide / 2;
      final count = (limb.startWidth * 700).round().clamp(2, 11);
      for (var i = 0; i < count; i++) {
        final offset = (rand.nextDouble() - 0.5) * 2 * half;
        final t0 = rand.nextDouble() * 0.7;
        final t1 = (t0 + 0.15 + rand.nextDouble() * 0.5).clamp(0.0, 1.0);
        final path = Path();
        for (var s = 0; s <= 8; s++) {
          final t = t0 + (t1 - t0) * (s / 8);
          final p = quadPointAt(a, b, c, t);
          final tangent = quadTangentAt(a, b, c, t);
          final length = tangent.distance;
          final normal = length == 0
              ? Offset.zero
              : Offset(-tangent.dy / length, tangent.dx / length);
          final at = p + normal * (offset * (1 - t * 0.55));
          if (s == 0) {
            path.moveTo(at.dx, at.dy);
          } else {
            path.lineTo(at.dx, at.dy);
          }
        }
        streak
          ..color = widget.paperColor.withValues(alpha: 0.08 + rand.nextDouble() * 0.22)
          ..strokeWidth = half * (0.05 + rand.nextDouble() * 0.15);
        canvas.drawPath(path, streak);
      }
    }

    // Pigment settling along stroke edges
    canvas.drawPath(
      wood.shift(Offset(size.shortestSide * 0.0025, size.shortestSide * 0.0010)),
      Paint()
        ..color = ink.withValues(alpha: 0.38)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur * 0.8),
    );

    canvas.restore();
  }

  /// Trunk, roots, branches and twigs painted with vivid glowing colors per segment for manual debugging.
  void _paintWoodDebugColors(Canvas canvas, Size size) {
    final limbs = widget.geometry.limbs;
    if (limbs.isEmpty) return;

    // Distinct vibrant color palette for debug glowing segments
    const glowColors = [
      Color(0xFFFF0055), // Neon Magenta/Red
      Color(0xFFFF6600), // Bright Orange
      Color(0xFFFFD700), // Electric Gold
      Color(0xFF00FF66), // Neon Spring Green
      Color(0xFF00E5FF), // Bright Cyan
      Color(0xFF3366FF), // Royal Blue
      Color(0xFF9933FF), // Electric Violet
      Color(0xFFFF00CC), // Hot Pink
      Color(0xFF00FFBB), // Bright Teal
      Color(0xFFFF3300), // Bright Coral Red
      Color(0xFFCCFF00), // Lime Green
      Color(0xFFFF9900), // Bright Amber
      Color(0xFF0099FF), // Sky Blue
      Color(0xFFE040FB), // Orchid
      Color(0xFF76FF03), // Electric Lime
      Color(0xFFFF1744), // Crimson
    ];

    // Helper to render a glowing segment with label badge
    void drawGlowSegment(Path path, Color color, String label, Offset center) {
      final glowBlur = size.shortestSide * 0.015;
      final midBlur = size.shortestSide * 0.006;

      // 1. Wide outer soft glow
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.65)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, glowBlur),
      );

      // 2. Focused stroke glow
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.shortestSide * 0.004
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, midBlur),
      );

      // 3. Crisp solid color fill
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );

      // 4. Sharp white inner border highlight
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.90)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );

      // 5. Segment label badge
      final textSpan = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      );
      final tp = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final badgeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          center.dx - tp.width / 2 - 4,
          center.dy - tp.height / 2 - 2,
          tp.width + 8,
          tp.height + 4,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(badgeRect, Paint()..color = Colors.black.withValues(alpha: 0.82));
      canvas.drawRRect(badgeRect, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
      tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
    }

    Offset toPixels(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

    // 1. Trunk (limb index 0): Subdivide into Trunk-0 (sliver t=-0.02..0.07) and Trunk-1..5
    final trunk = limbs[0];
    final trunkRanges = <(double, double)>[
      (-0.02, 0.07), // Trunk-0 (Sliver)
      (0.07, 0.20), // Trunk-1
      (0.20, 0.40), // Trunk-2
      (0.40, 0.60), // Trunk-3
      (0.60, 0.80), // Trunk-4
      (0.80, 1.00), // Trunk-5
    ];

    for (var s = 0; s < trunkRanges.length; s++) {
      final (tStart, tEnd) = trunkRanges[s];
      final tMid = (tStart + tEnd) / 2;

      final path = _limbRibbon(
        trunk,
        size,
        roundBase: false,
        tStart: tStart,
        tEnd: tEnd,
      );
      final color = glowColors[s % glowColors.length];
      final label = 'Trunk-$s';

      final center = quadPointAt(
        toPixels(trunk.start),
        toPixels(trunk.control),
        toPixels(trunk.end),
        tMid,
      );

      drawGlowSegment(path, color, label, center);
    }

    // 2. Roots and Branches/Twigs (limbs index 1..N): Each limb gets a distinct glowing segment & color
    for (var i = 1; i < limbs.length; i++) {
      final limb = limbs[i];
      final roundBase = limb.start != widget.geometry.trunkBase;
      final path = _limbRibbon(limb, size, roundBase: roundBase);
      final color = glowColors[(i + 4) % glowColors.length];

      final isRoot = i <= 8; // Indices 1..8 are root limbs
      final label = isRoot ? 'Root-$i' : 'Branch-$i';

      final center = quadPointAt(
        toPixels(limb.start),
        toPixels(limb.control),
        toPixels(limb.end),
        0.5,
      );

      drawGlowSegment(path, color, label, center);
    }
  }

  /// A closed pool outline: an ellipse whose radius is perturbed by three
  /// harmonics, smoothed through the midpoints of the sampled ring. The
  /// highest harmonic runs fast enough to lobe the edge rather than merely
  /// dent it, which is what turns an amoeba into a watercolour bloom.
  Path _cellPath(WashCell cell, Size size) {
    final cx = cell.center.dx * size.width;
    final cy = cell.center.dy * size.height;
    final rx = cell.radiusX * size.width;
    final ry = cell.radiusY * size.height;
    const steps = 34;

    final points = <Offset>[];
    for (var i = 0; i < steps; i++) {
      final a = i / steps * math.pi * 2;
      final k = 1 +
          cell.wobbleAmount *
              (0.52 * math.sin(3 * a + cell.wobblePhases[0]) +
                  0.30 * math.sin(7 * a + cell.wobblePhases[1]) +
                  0.22 * math.sin(13 * a + cell.wobblePhases[2]));
      final angle = a + cell.rotation;
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();

        final palette = buildTonePalette(widget.leafColors);
        _ensureAtlas(palette);
        _ensureLandedAtlas(palette);
        _ensureGrain(widget.inkColor);
        _ensureScene(size, palette, MediaQuery.devicePixelRatioOf(context));
        final glowPath = _hoverGlow > 0.001 || widget.hovered
            ? _glowPathFor(size)
            : null;

        final atlas = _atlas;
        final landedAtlas = _landedAtlas;
        final background = _background;
        final grainShader = _grainShader;
        if (atlas == null ||
            landedAtlas == null ||
            background == null ||
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
              grainShader: grainShader,
              atlas: atlas,
              landedAtlas: landedAtlas,
              leafCellRects: _leafCellRects,
              rstBuffer: _rstBuffer,
              rectBuffer: _rectBuffer,
              landedRstBuffer: _landedRstBuffer,
              landedRectBuffer: _landedRectBuffer,
              restPositions: _restPositions,
              restRotations: _restRotations,
              fallenDiameters: _fallenDiameters,
              colorCount: palette.length,
              time: _time,
              // Passed live rather than copied: the painter only reads them,
              // and snapshotting the fall map rebuilt a 4160-entry map every
              // frame for the whole opening animation.
              gusts: _gusts,
              falling: _falling,
              groundedLeafIndices: widget.groundedLeafIndices,
              landedThisSession: _landedThisSession,
              glowPath: glowPath,
              hoverGlow: _hoverGlow,
              glowColor: widget.accentColor,
            ),
          ),
        );
      },
    );
  }
}

/// The trunk/root/branch silhouette as one unioned path — every limb, plus
/// fillets at every joint. Shared by [_LifeTreeCanvasState]'s static-layer
/// bake and hover glow, and by the branches-only variant below.
Path buildTreeWoodPath(LifeTreeGeometry geometry, Size size) {
  var wood = Path();
  for (var i = 0; i < geometry.limbs.length; i++) {
    final limb = geometry.limbs[i];
    final roundBase = i == 0 ? false : (limb.start != geometry.trunkBase);
    final tStart = i == 0 ? -0.02 : 0.0;
    wood = Path.combine(
      PathOperation.union,
      wood,
      _limbRibbon(limb, size, roundBase: roundBase, tStart: tStart),
    );
  }
  return Path.combine(
    PathOperation.union,
    wood,
    _limbJointPatches(geometry.limbs, size, geometry.trunkBase),
  );
}

/// The trunk plus the branches fanning out above its fork — [geometry.limbs]
/// minus the root flares (see [LifeTreeGeometry.branchLimbStartIndex]). Used
/// for the bucket-list tap target and the hover glow, which per user request
/// should respond over the trunk and branches but not the root flares or the
/// canopy wash.
Path buildTrunkAndBranchesPath(LifeTreeGeometry geometry, Size size) {
  final limbs = [
    geometry.limbs[0],
    ...geometry.limbs.sublist(geometry.branchLimbStartIndex),
  ];
  var wood = Path();
  for (var i = 0; i < limbs.length; i++) {
    final limb = limbs[i];
    // The trunk (i == 0) keeps the same flat, unrounded base cap it gets in
    // buildTreeWoodPath — it sits down near the ground line either way, so
    // the cap shape isn't visible in practice.
    final roundBase = i == 0 ? false : (limb.start != geometry.trunkBase);
    wood = Path.combine(
      PathOperation.union,
      wood,
      _limbRibbon(limb, size, roundBase: roundBase),
    );
  }
  return Path.combine(
    PathOperation.union,
    wood,
    _limbJointPatches(limbs, size, geometry.trunkBase),
  );
}

/// Sumi-e calligraphic brush stroke ribbon with rounded tip/base caps and
/// smooth curves. [roundBase] should be false for a limb whose start sits
/// in a multi-limb joint already closed by [_limbJointPatches] — see the
/// call in [_LifeTreeCanvasState._paintWood].
Path _limbRibbon(
  TreeLimb limb,
  Size size, {
  bool roundBase = true,
  double tStart = 0.0,
  double tEnd = 1.0,
}) {
  Offset toPixels(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

  final a = toPixels(limb.start);
  final b = toPixels(limb.control);
  final c = toPixels(limb.end);
  final startHalf = limb.startWidth * size.shortestSide / 2;
  final endHalf = limb.endWidth * size.shortestSide / 2;
  const steps = 30;

  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i <= steps; i++) {
    final subT = i / steps;
    final t = tStart + (tEnd - tStart) * subT;
    final p = quadPointAt(a, b, c, t);
    final tangent = quadTangentAt(a, b, c, t);
    final length = tangent.distance;
    final normal = length == 0
        ? Offset.zero
        : Offset(-tangent.dy / length, tangent.dx / length);
    final half = _plainTaperHalf(t, startHalf, endHalf);
    left.add(p + normal * half);
    right.add(p - normal * half);
  }

  Offset mid(Offset p1, Offset p2) => Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);

  final path = Path()..moveTo(left.first.dx, left.first.dy);
  for (var i = 0; i < left.length - 1; i++) {
    final m = mid(left[i], left[i + 1]);
    path.quadraticBezierTo(left[i].dx, left[i].dy, m.dx, m.dy);
  }
  path.lineTo(left.last.dx, left.last.dy);

  if (tEnd == 1.0) {
    // Smooth rounded tip cap
    path.quadraticBezierTo(c.dx, c.dy, right.last.dx, right.last.dy);
  } else {
    path.lineTo(right.last.dx, right.last.dy);
  }

  for (var i = right.length - 1; i > 0; i--) {
    final m = mid(right[i], right[i - 1]);
    path.quadraticBezierTo(right[i].dx, right[i].dy, m.dx, m.dy);
  }
  path.lineTo(right.first.dx, right.first.dy);

  if (tStart <= 0.0 && roundBase) {
    // Rounded base cap
    final tangent0 = quadTangentAt(a, b, c, tStart);
    final tangent0Length = tangent0.distance;
    final p0 = quadPointAt(a, b, c, tStart);
    final baseCapControl = tangent0Length == 0
        ? p0
        : p0 - tangent0 / tangent0Length * startHalf;
    path.quadraticBezierTo(baseCapControl.dx, baseCapControl.dy, left.first.dx, left.first.dy);
  } else {
    path.lineTo(left.first.dx, left.first.dy);
  }

  return path..close();
}

/// The ribbon-edge corners a limb presents at parameter [t] — the same
/// left/right offset points [_limbRibbon] itself traces there, using its
/// identical taper/pressure formula, so anything built from these meets the
/// ribbon with no seam.
(Offset, Offset) _limbEdgeAt(TreeLimb limb, double t, Size size) {
  Offset toPixels(Offset n) => Offset(n.dx * size.width, n.dy * size.height);
  final a = toPixels(limb.start);
  final b = toPixels(limb.control);
  final c = toPixels(limb.end);
  final startHalf = limb.startWidth * size.shortestSide / 2;
  final endHalf = limb.endWidth * size.shortestSide / 2;
  final p = quadPointAt(a, b, c, t);
  final tangent = quadTangentAt(a, b, c, t);
  final length = tangent.distance;
  final normal =
      length == 0 ? const Offset(0, 1) : Offset(-tangent.dy / length, tangent.dx / length);
  final half = _plainTaperHalf(t, startHalf, endHalf);
  return (p + normal * half, p - normal * half);
}

double _plainTaperHalf(double t, double startHalf, double endHalf) {
  final taper = math.pow(1 - t, 1.3).toDouble();
  final pressure = 1.0 + 0.12 * math.sin(t * math.pi);
  return math.max((endHalf + (startHalf - endHalf) * taper) * pressure, 0.4);
}

/// The two ribbon-edge corners a limb presents at its start (t=0) or end
/// (t=1).
(Offset, Offset) _limbShoulders(TreeLimb limb, bool atStart, Size size) {
  return _limbEdgeAt(limb, atStart ? 0.0 : 1.0, size);
}

/// Fills every wedge left where limbs meet — a continuation or a fork. Each
/// ribbon tapers to a flat cap exactly at its own endpoint (see
/// [_limbRibbon]), so where two or more meet at different angles their caps
/// don't line up, leaving a straight-edged gap across the union.
///
/// The patch is the convex hull of every limb's corners at the point —
/// not a fan connecting them in angle order, which was tried first and
/// looks right whenever the limbs meeting there are similar widths (the
/// crown fork), but breaks when the corners aren't already in convex
/// position: connecting them strictly in the order their angle-from-the-
/// point happens to fall in can walk *inward* before reaching the next
/// one, cutting a concave notch out of the patch rather than extending it.
/// A hull can't do that by construction. A small supplementary circle at
/// the point absorbs the case a plain hull still falls short in: a
/// much-thinner neighbour's corner can sit close enough to the point that
/// the wide limb's own hull edge passes outside it anyway (position scales
/// by width and height separately; thickness scales only by the shortest
/// side, so this shortfall's size shifts with window shape even though the
/// limbs' thickness doesn't). A circle large enough to reach the single
/// widest limb's own corner is guaranteed to close every gap at any aspect
/// ratio (every corner sits at a distance from the point of exactly its
/// own half-width, so nothing can poke past a circle that size) — but is
/// overkill for the sliver actually seen in practice and reads as a bulb
/// stuck onto the joint. Sized down to 60% of that instead: still enough
/// to close the gap at every aspect ratio this was checked against (very
/// wide to portrait), while looking like a natural root collar rather than
/// a foreign ball joint. Applied everywhere, including the trunk's own
/// base: the hull there is built only from each limb's corner exactly at
/// the shared point, so once the roots' own angles diverge sharply enough
/// — as the root fan's do — the hull's flat facet between them sits well
/// short of where the ribbons themselves have already pulled apart,
/// leaving a sharp notch under the trunk. The circle is what closes that.
/// [trunkBase] is skipped since the multi-root fan there is closed by its
/// own dedicated collar — pass a point that can't match any joint (e.g. an
/// endpoint far off the unit square) to patch every joint unconditionally.
Path _limbJointPatches(List<TreeLimb> limbs, Size size, Offset trunkBase) {
  final refs = <Offset, List<(TreeLimb, bool)>>{};
  void note(Offset point, TreeLimb limb, bool isStart) {
    refs.putIfAbsent(point, () => []).add((limb, isStart));
  }
  for (final limb in limbs) {
    note(limb.start, limb, true);
    note(limb.end, limb, false);
  }

  Offset toPixels(Offset n) => Offset(n.dx * size.width, n.dy * size.height);
  final patches = Path();

  refs.forEach((point, ends) {
    if (ends.length < 2) return;
    if (point == trunkBase) return;
    final pixel = toPixels(point);
    final corners = <Offset>[];
    var maxHalf = 0.0;
    for (final (limb, isStart) in ends) {
      final (left, right) = _limbShoulders(limb, isStart, size);
      corners..add(left)..add(right);
      final half = (isStart ? limb.startWidth : limb.endWidth) / 2;
      if (half > maxHalf) maxHalf = half;
    }
    final hull = _convexHull(corners);
    patches.moveTo(hull.first.dx, hull.first.dy);
    for (final corner in hull.skip(1)) {
      patches.lineTo(corner.dx, corner.dy);
    }
    patches.close();
    patches.addOval(
      Rect.fromCircle(center: pixel, radius: maxHalf * size.shortestSide * 0.6),
    );
  });

  // A bough forking off partway along a thicker parent's length, rather
  // than at one of the parent's own two endpoints, never shares a
  // coordinate with anything — so it gets no fillet above, and its own
  // flat base cap (see [_limbRibbon]) pokes out of the parent's side as a
  // knob wherever it doesn't line up with the parent's edge. Detected by
  // containment rather than by coordinate, since nothing else marks a
  // point as "inside another limb's ribbon." Kept small — just enough to
  // round off that limb's own cap, not to blend into the parent besides.
  for (final limb in limbs) {
    for (final isStart in const [true, false]) {
      final point = isStart ? limb.start : limb.end;
      if (refs[point]!.length >= 2) continue;
      final pixel = toPixels(point);
      for (final other in limbs) {
        if (identical(other, limb)) continue;
        if (other.start == point || other.end == point) continue;
        if (_limbRibbon(other, size).contains(pixel)) {
          final half = (isStart ? limb.startWidth : limb.endWidth) / 2;
          patches.addOval(
            Rect.fromCircle(center: pixel, radius: half * size.shortestSide * 1.05),
          );
          break;
        }
      }
    }
  }

  return patches;
}

/// Convex hull via Andrew's monotone chain — points sorted lexicographically,
/// then a lower and upper chain each built by dropping the last point
/// whenever the next one would turn clockwise (a non-left turn), so both
/// chains bow outward only. Returns points in counter-clockwise order,
/// duplicates collapsed. Deliberately not the simpler "sort by angle from
/// the joint and connect" — that only traces the true outer boundary when
/// every point is already someone's single extremum in that direction, and
/// [_limbJointPatches] can hand it a limb's corner at two different
/// distances from the same point.
List<Offset> _convexHull(List<Offset> points) {
  final pts = points.toSet().toList()
    ..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  if (pts.length < 3) return pts;

  double cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

  final lower = <Offset>[];
  for (final p in pts) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }

  final upper = <Offset>[];
  for (final p in pts.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }

  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// A wash cell's live sway, resolved once per frame and applied to every
/// stipple speck sitting on it.
class _CellTransform {
  _CellTransform(this.cos, this.sin, this.pivot, this.roll);

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
    required this.grainShader,
    required this.atlas,
    required this.landedAtlas,
    required this.leafCellRects,
    required this.rstBuffer,
    required this.rectBuffer,
    required this.landedRstBuffer,
    required this.landedRectBuffer,
    required this.restPositions,
    required this.restRotations,
    required this.fallenDiameters,
    required this.colorCount,
    required this.time,
    required this.gusts,
    required this.falling,
    required this.groundedLeafIndices,
    required this.landedThisSession,
    required this.glowPath,
    required this.hoverGlow,
    required this.glowColor,
  });

  static const _spriteExtent = 96.0;

  final LifeTreeGeometry geometry;

  /// Paper, canopy wash, wood, grass and the figure, pre-rasterized at canvas
  /// size for the current shed level.
  final ui.Image background;
  final ui.ImageShader grainShader;
  final ui.Image atlas;

  /// Same sprites as [atlas], baked brighter — used for leaves that have
  /// landed and settled on the ground.
  final ui.Image landedAtlas;
  final List<Rect> leafCellRects;
  final Float32List rstBuffer;
  final Float32List rectBuffer;
  final Float32List landedRstBuffer;
  final Float32List landedRectBuffer;
  final List<Offset> restPositions;
  final Float32List restRotations;

  /// Pixel diameter each leaf is drawn at once it's detached from the canopy
  /// (falling or landed), keyed by leaf index — see [fallenLeafDiameterFor].
  final Float32List fallenDiameters;
  final int colorCount;
  final double time;
  final List<_LeafShudder> gusts;
  final Map<int, _FallingLeaf> falling;
  final Set<int> groundedLeafIndices;
  final Set<int> landedThisSession;

  /// The branches' own silhouette, for the hover glow — null whenever the
  /// glow is fully faded out, so a hover that never happens costs nothing.
  final Path? glowPath;

  /// Eased 0-1 strength of the branch hover glow.
  final double hoverGlow;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final breathe = 1 + math.sin(time * 0.34) * 0.004;
    final pivot = Offset(
      geometry.trunkTop.dx * size.width,
      geometry.trunkTop.dy * size.height,
    );
    final transforms = _resolveCellTransforms(size);

    canvas.drawImageRect(
      background,
      Offset.zero &
          Size(background.width.toDouble(), background.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );

    // The wash underneath does not sway with its cell. At a peak roll of about
    // a degree on pigment this faint the motion was never visible, and holding
    // it still is what lets the whole background be one texture. The stipple
    // over it still sways and breathes.
    _paintStipple(canvas, size, transforms, pivot, breathe);

    if (hoverGlow > 0.001) _paintTreeGlow(canvas, size);
  }

  /// A soft accent-tinted halo along just the branches, faded in by
  /// [hoverGlow]. Scoped to match the same region that triggers it (see the
  /// branches-only clip in life_tracker_page.dart) and the same region the
  /// bucket-list tap responds to — hovering a branch lights only that
  /// branch fan, not the trunk, roots, or canopy.
  void _paintTreeGlow(Canvas canvas, Size size) {
    final branches = glowPath;
    if (branches == null) return;
    final alpha = hoverGlow;

    canvas.drawPath(
      branches,
      Paint()
        ..color = glowColor.withValues(alpha: 0.45 * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.012
        ..maskFilter = ui.MaskFilter.blur(
          ui.BlurStyle.normal,
          size.shortestSide * 0.012,
        ),
    );
    canvas.drawPath(
      branches,
      Paint()
        ..color = glowColor.withValues(alpha: 0.30 * alpha)
        ..maskFilter = ui.MaskFilter.blur(
          ui.BlurStyle.normal,
          size.shortestSide * 0.006,
        ),
    );
  }

  /// The canopy breathes as one: every cell shares a slow global scale about
  /// the trunk's fork, with only a fractional-degree roll of its own. A gust
  /// adds a brief localized shiver.
  List<_CellTransform> _resolveCellTransforms(Size size) {
    final pivot = Offset(
      geometry.trunkTop.dx * size.width,
      geometry.trunkTop.dy * size.height,
    );
    return [
      for (final cell in geometry.cells)
        () {
          var shiver = 0.0;
          for (final gust in gusts) {
            shiver += gust.extraAt(cell.center);
          }
          final roll = math.sin(time * 0.34 + cell.swayPhase) * 0.006 +
              math.sin(time * 7.5 + cell.swayPhase) * 0.02 * shiver;
          return _CellTransform(math.cos(roll), math.sin(roll), pivot, roll);
        }(),
    ];
  }

  /// Every one of the 4160 weeks, as one speck of blossom over the wash.
  /// Attached specks ride their pool's sway; detached ones fall free, and a
  /// landed one stays where it settled.
  void _paintStipple(
    Canvas canvas,
    Size size,
    List<_CellTransform> transforms,
    Offset pivot,
    double breathe,
  ) {
    final leaves = geometry.leaves;
    const anchor = _spriteExtent / 2;

    // Split across two buffers/atlases rather than one: a landed leaf is
    // drawn from landedAtlas at _landedLeafAlpha (70% opacity) instead of the
    // faint on-tree stipple alpha, so it reads clearly against the grass.
    var liveCount = 0;
    var landedCount = 0;

    for (var i = 0; i < leaves.length; i++) {
      final leaf = leaves[i];
      final fallingLeaf = falling[i];
      final isGrounded =
          groundedLeafIndices.contains(i) || landedThisSession.contains(i);
      final settled = isGrounded && fallingLeaf == null;

      double x;
      double y;
      double angle;

      if (settled) {
        final at = restPositions[i];
        x = at.dx * size.width;
        y = at.dy * size.height;
        angle = restRotations[i];
      } else if (fallingLeaf != null && fallingLeaf.hasStarted) {
        final p = fallingLeaf.progress;
        final t = Curves.easeIn.transform(p);
        final ground = restPositions[i];
        final drift =
            math.sin(p * math.pi * 2.3 + leaf.swayPhase) * 0.010 * (1 - t);
        x = (leaf.position.dx + (ground.dx - leaf.position.dx) * t + drift) *
            size.width;
        y = (leaf.position.dy + (ground.dy - leaf.position.dy) * t) * size.height;
        angle = leaf.baseAngle +
            (restRotations[i] - leaf.baseAngle) * t +
            math.sin(p * 5.5 + leaf.swayPhase) * 0.6 * (1 - t);
      } else {
        // Still on the tree: sways with its pool, breathes with the crown.
        final transform = transforms[leaf.cellIndex];
        final swayed = transform.apply(
          Offset(leaf.position.dx * size.width, leaf.position.dy * size.height),
        );
        x = pivot.dx + (swayed.dx - pivot.dx) * breathe;
        y = pivot.dy + (swayed.dy - pivot.dy) * breathe;
        angle = leaf.baseAngle + transform.roll;
      }

      // Detached leaves (falling or landed) are drawn at a fixed pixel size
      // matching the background petal field, instead of the tiny stipple
      // grain they read as while still part of the canopy texture.
      final detached = settled || (fallingLeaf != null && fallingLeaf.hasStarted);
      final scale = detached
          ? fallenDiameters[i] / _spriteExtent
          : leaf.size * size.shortestSide * 2 / _spriteExtent;
      final scos = math.cos(angle) * scale;
      final ssin = math.sin(angle) * scale;

      final cellIndex =
          leaf.designIndex * colorCount + leaf.colorIndex.clamp(0, colorCount - 1);
      final cell = leafCellRects[cellIndex.clamp(0, leafCellRects.length - 1)];

      final rst = settled ? landedRstBuffer : rstBuffer;
      final rect = settled ? landedRectBuffer : rectBuffer;
      final slot = settled ? landedCount++ : liveCount++;
      final t = slot * 4;

      rst[t] = scos;
      rst[t + 1] = ssin;
      rst[t + 2] = x - (scos * anchor - ssin * anchor);
      rst[t + 3] = y - (ssin * anchor + scos * anchor);

      rect[t] = cell.left;
      rect[t + 1] = cell.top;
      rect[t + 2] = cell.right;
      rect[t + 3] = cell.bottom;
    }

    // Multiplied into the wash, not laid over it. Painted normally, every
    // speck reads as a separate object sitting on the surface of the
    // picture; multiplied, it reads as more pigment in the same paper.
    // (The blendMode argument above tints sprites against the colors list,
    // which is unused here — the compositing mode has to come off the paint.)
    final paint = Paint()..filterQuality = FilterQuality.low;

    if (liveCount > 0) {
      canvas.drawRawAtlas(
        atlas,
        rstBuffer.buffer.asFloat32List(0, liveCount * 4),
        rectBuffer.buffer.asFloat32List(0, liveCount * 4),
        null,
        null,
        null,
        paint,
      );
    }
    if (landedCount > 0) {
      canvas.drawRawAtlas(
        landedAtlas,
        landedRstBuffer.buffer.asFloat32List(0, landedCount * 4),
        landedRectBuffer.buffer.asFloat32List(0, landedCount * 4),
        null,
        null,
        null,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LifeTreePainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.gusts.length != gusts.length ||
        oldDelegate.falling.length != falling.length ||
        oldDelegate.landedThisSession.length != landedThisSession.length ||
        oldDelegate.hoverGlow != hoverGlow ||
        !identical(oldDelegate.background, background) ||
        !identical(oldDelegate.atlas, atlas) ||
        !identical(oldDelegate.landedAtlas, landedAtlas);
  }
}

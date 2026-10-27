import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Dissolves a sent prompt into particles where its text stood, swept from
/// right to left (after Aceternity UI's "placeholders and vanish input").
/// The field is already empty underneath, so the next prompt can be typed
/// straight away; typing fades the effect out early.
///
/// Without a [controller], it dissolves everything [builder] painted
/// instead, such as a draft's images, and closes away entirely.
class GaiaVanish extends StatefulWidget {
  const GaiaVanish({
    super.key,
    this.controller,
    this.refilled = false,
    required this.builder,
  });

  final TextEditingController? controller;

  /// Without a [controller]: turning true fades the effect out early, as
  /// typing does, once there's something new to show.
  final bool refilled;

  /// Builds the text field. While [vanishing], the field should expand to
  /// the height it's given (it closes smoothly once the text has been
  /// swept), align its text to the top and hide its hint. Without a
  /// [controller], what's built is held at its height until it closes.
  final Widget Function(BuildContext context, bool vanishing) builder;

  @override
  State<GaiaVanish> createState() => GaiaVanishState();
}

class GaiaVanishState extends State<GaiaVanish>
    with SingleTickerProviderStateMixin {
  static const _closing = Duration(milliseconds: 350);

  late final Ticker _ticker;
  _Vanishing? _vanishing;
  bool _fading = false;

  /// The field's height while vanishing; null lets it size itself.
  final _height = ValueNotifier<double?>(null);
  Duration? _closingFrom;

  /// Around what's built, without a [GaiaVanish.controller].
  final _snapshot = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.controller?.addListener(_onEdit);
  }

  @override
  void didUpdateWidget(GaiaVanish oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onEdit);
      widget.controller?.addListener(_onEdit);
    }
    if (widget.refilled && !oldWidget.refilled) _fadeOut();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onEdit);
    _ticker.dispose();
    _vanishing?.dispose();
    _height.dispose();
    super.dispose();
  }

  /// Snapshots the field's text as laid out on screen, or without a
  /// controller, all that's built. Call just before clearing it.
  void vanish() => vanishTogether([this]);

  /// Vanishes each of [states] as [vanish] does, under one sweep, like a
  /// single line drawn across the screen: it starts at the rightmost ink of
  /// any of them and crosses them all at one speed, so each starts to
  /// dissolve only once the line reaches it.
  static void vanishTogether(List<GaiaVanishState> states) {
    final captured = [
      for (final state in states)
        if (state._capture() case final vanishing?) (state, vanishing),
    ];
    Future.wait([
      for (final (_, vanishing) in captured) vanishing.sample(),
    ]).then((_) {
      final live = [
        for (final (state, vanishing) in captured)
          if (state.mounted &&
              identical(state._vanishing, vanishing) &&
              !state._fading)
            (state, vanishing),
      ];
      final inked = [
        for (final (_, vanishing) in live)
          if (vanishing.inked) vanishing,
      ];
      final right = inked.isEmpty
          ? 0.0
          : inked.map((v) => v.left + v.right).reduce(math.max);
      final left = inked.isEmpty
          ? 0.0
          : inked.map((v) => v.left).reduce(math.min);
      // 8px a step like the original, but never longer than ~0.75s a sweep.
      final speed = math.max(8.0, (right - left) / 45);
      // Started together, the tickers step in lockstep from the same frame.
      for (final (state, vanishing) in live) {
        vanishing.begin(right - vanishing.left, speed);
        state._ticker.start();
      }
    });
  }

  _Vanishing? _capture() {
    if (MediaQuery.disableAnimationsOf(context)) return null;
    final box = context.findRenderObject()! as RenderBox;
    final editable = widget.controller == null ? null : findEditable(box)!;
    _clear();
    final vanishing = editable == null
        ? _Vanishing.snapshot(
            _snapshot.currentContext!.findRenderObject()!
                as RenderRepaintBoundary,
            MediaQuery.devicePixelRatioOf(context),
          )
        : _Vanishing.capture(editable, box);
    vanishing.left = box.localToGlobal(vanishing.origin).dx;
    _height.value = vanishing.fieldHeight;
    setState(() {
      _vanishing = vanishing;
      _fading = false;
    });
    return vanishing;
  }

  void _tick(Duration elapsed) {
    final vanishing = _vanishing!;
    final particles = vanishing.advance(elapsed);
    // What was built only closes once its particles are gone: they leave
    // sideways, rather than being swallowed by its top edge coming down.
    if (!vanishing.swept || (particles && widget.controller == null)) return;
    // Close the field to one line while the last particles settle.
    _closingFrom ??= elapsed;
    final t = math.min(
      1.0,
      (elapsed - _closingFrom!).inMicroseconds / _closing.inMicroseconds,
    );
    _height.value = ui.lerpDouble(
      vanishing.fieldHeight,
      vanishing.closedHeight,
      Curves.easeInOut.transform(t),
    );
    if (!particles && t == 1) setState(_clear);
  }

  void _clear() {
    _ticker.stop();
    _vanishing?.dispose();
    _vanishing = null;
    _closingFrom = null;
    _height.value = null;
  }

  void _onEdit() {
    if (widget.controller!.text.isNotEmpty) _fadeOut();
  }

  void _fadeOut() {
    if (_vanishing == null || _fading) return;
    // What's new to show takes its own height straight away, rather than
    // the closing one's while the effect fades.
    if (widget.controller == null) {
      _ticker.stop();
      _height.value = null;
    }
    setState(() => _fading = true);
  }

  @override
  Widget build(BuildContext context) {
    final vanishing = _vanishing;
    final built = widget.builder(context, vanishing != null);
    return Stack(
      children: [
        ValueListenableBuilder(
          valueListenable: _height,
          builder: (context, height, field) =>
              SizedBox(height: height, child: field),
          child: widget.controller == null
              ? RepaintBoundary(key: _snapshot, child: built)
              : built,
        ),
        if (vanishing != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: const Duration(milliseconds: 120),
                onEnd: () {
                  if (_fading) setState(_clear);
                },
                child: RepaintBoundary(
                  child: CustomPaint(painter: _VanishPainter(vanishing)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One prompt's text turning to particles. Particles are kept in flat typed
/// arrays and drawn in a single [Canvas.drawRawAtlas] call per frame.
class _Vanishing extends ChangeNotifier {
  _Vanishing._(
    this.origin,
    this.size,
    this.picture,
    this.fieldHeight,
    this.closedHeight,
  );

  /// Lays the text out again the way [editable] did and records it, shifted
  /// to where [editable] paints it (wrapping, padding and scroll included).
  /// [field] is the box the overlay covers.
  factory _Vanishing.capture(RenderEditable editable, RenderBox field) {
    final painter = TextPainter(
      text: editable.text,
      textAlign: editable.textAlign,
      textDirection: editable.textDirection,
      textScaler: editable.textScaler,
      locale: editable.locale,
      maxLines: editable.maxLines == 1 ? 1 : null,
      strutStyle: editable.strutStyle,
      textHeightBehavior: editable.textHeightBehavior,
      textWidthBasis: editable.textWidthBasis,
    );
    // RenderEditable keeps 1px plus the cursor's width free for the caret.
    final width = math.max(0.0, editable.size.width - 1 - editable.cursorWidth);
    painter.layout(
      minWidth: width,
      maxWidth: editable.maxLines == 1 ? double.infinity : width,
    );
    final all = TextSelection(
      baseOffset: 0,
      extentOffset: painter.plainText.length,
    );
    final ours = painter.getBoxesForSelection(
      all,
      boxHeightStyle: editable.selectionHeightStyle,
      boxWidthStyle: editable.selectionWidthStyle,
    );
    final theirs = editable.getBoxesForSelection(all);
    final shift = ours.isEmpty || theirs.isEmpty
        ? Offset.zero
        : Offset(
            theirs.first.left - ours.first.left,
            theirs.first.top - ours.first.top,
          );

    final size = editable.size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size)
      ..clipRect(Offset.zero & size);
    painter.paint(canvas, shift);
    painter.dispose();
    final fieldHeight = field.size.height;
    return _Vanishing._(
      editable.localToGlobal(Offset.zero, ancestor: field),
      size,
      recorder.endRecording(),
      fieldHeight,
      fieldHeight - size.height + editable.preferredLineHeight,
    );
  }

  /// Records what [boundary] painted, at [pixelRatio], to close away
  /// entirely.
  factory _Vanishing.snapshot(
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) {
    final size = boundary.size;
    final image = boundary.toImageSync(pixelRatio: pixelRatio);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    // The picture holds on to the image itself.
    image.dispose();
    return _Vanishing._(
      Offset.zero,
      size,
      recorder.endRecording(),
      size.height,
      0,
    );
  }

  /// Where the text's viewport sat in the field when sent.
  final Offset origin;
  final Size size;

  /// [origin] across the screen, where vanishings share their sweep.
  late final double left;

  /// The text (or snapshot) as it looked, drawn left of the sweep until it
  /// dissolves.
  final ui.Picture picture;

  /// The field's height when sent, and once closed: holding a single empty
  /// line, or nothing at all for a snapshot.
  final double fieldHeight;
  final double closedHeight;

  /// Whether the sweep has released every particle.
  bool get swept => _next == _count;

  /// Once sampled: whether there's any ink, and just right of the
  /// rightmost.
  bool get inked => _count > 0;
  double get right => _sourceX[0] + 1;

  // Pixels below this alpha are anti-aliasing fringe, not worth a particle.
  static const _minAlpha = 48;
  static const _stepsPerSecond = 60;

  static final ui.Image _dot = () {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    return recorder.endRecording().toImageSync(1, 1);
  }();
  static final _paint = Paint()..filterQuality = FilterQuality.none;

  final _random = math.Random();
  bool _disposed = false;

  // Every inked pixel, rightmost column first, so the sweep releases them
  // in order from [_next].
  int _count = 0;
  int _next = 0;
  late Float32List _sourceX, _sourceY, _sourceAlpha;
  late Int32List _sourceRgb;

  // Particles the sweep has passed, compacted into [0, _live).
  int _live = 0;
  late Float32List _transforms, _rects, _radius, _alpha;
  late Int32List _rgb, _colors;

  double _sweep = double.infinity;
  double _speed = 0;
  int _steps = 0;

  /// Reads the recorded text back as pixels and turns each into a particle.
  Future<void> sample() async {
    final width = size.width.ceil();
    final height = size.height.ceil();
    final image = picture.toImageSync(width, height);
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    if (_disposed) return;
    final bytes = data!.buffer.asUint8List();

    var count = 0;
    for (var i = 3; i < bytes.length; i += 4) {
      if (bytes[i] >= _minAlpha) count++;
    }
    _sourceX = Float32List(count);
    _sourceY = Float32List(count);
    _sourceAlpha = Float32List(count);
    _sourceRgb = Int32List(count);
    for (var x = width - 1; x >= 0; x--) {
      for (var y = 0; y < height; y++) {
        final i = (y * width + x) * 4;
        final alpha = bytes[i + 3];
        if (alpha < _minAlpha) continue;
        _sourceX[_count] = x.toDouble();
        _sourceY[_count] = y.toDouble();
        _sourceAlpha[_count] = alpha / 255;
        _sourceRgb[_count] = bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2];
        _count++;
      }
    }

    _transforms = Float32List(count * 4);
    _rects = Float32List(count * 4);
    for (var i = 0; i < count; i++) {
      _transforms[i * 4] = 1; // scale 1, no rotation
      _rects[i * 4 + 2] = 1;
      _rects[i * 4 + 3] = 1;
    }
    _radius = Float32List(count);
    _alpha = Float32List(count);
    _rgb = Int32List(count);
    _colors = Int32List(count);
  }

  /// Starts the sweep at [sweep] across the text, moving [speed] a step.
  void begin(double sweep, double speed) {
    _sweep = sweep;
    _speed = speed;
  }

  /// Runs the fixed-rate steps due by [elapsed]. False once all are gone.
  bool advance(Duration elapsed) {
    final due = math.min(
      elapsed.inMicroseconds *
          _stepsPerSecond ~/
          Duration.microsecondsPerSecond,
      _steps + 4,
    );
    for (; _steps < due; _steps++) {
      _step();
    }
    notifyListeners();
    return _live > 0 || _next < _count;
  }

  void _step() {
    _sweep -= _speed;
    // Released before the walk, so they take this step too: an unmoved
    // block beside one that had moved left a thin seam between them.
    for (; _next < _count && _sourceX[_next] >= _sweep; _next++) {
      final to = _live * 4;
      _transforms[to + 2] = _sourceX[_next];
      _transforms[to + 3] = _sourceY[_next];
      _radius[_live] = 1;
      _alpha[_live] = _sourceAlpha[_next];
      _rgb[_live] = _sourceRgb[_next];
      _live++;
    }
    var kept = 0;
    for (var i = 0; i < _live; i++) {
      // Two moves of -1, 0 or 1 each way, and how much it shrinks, from one
      // draw. Always moving would split blocks released a step apart onto
      // alternate columns, which don't mesh.
      final bits = _random.nextInt(81 << 18);
      final radius = _radius[i] - 0.07 * (bits ~/ 81) / (1 << 18);
      if (radius <= 0) continue;
      final first = bits % 81 % 9, second = bits % 81 ~/ 9;
      final from = i * 4;
      final to = kept * 4;
      _transforms[to + 2] = _transforms[from + 2] + first % 3 + second % 3 - 2;
      _transforms[to + 3] =
          _transforms[from + 3] + first ~/ 3 + second ~/ 3 - 2;
      _radius[kept] = radius;
      _alpha[kept] = _alpha[i];
      _rgb[kept] = _rgb[i];
      _colors[kept] = (_alpha[i] * radius * 255).round() << 24 | _rgb[i];
      kept++;
    }
    _live = kept;
  }

  /// Paints into the field at its current [height]: anchored to its bottom
  /// edge, so a closing field's top edge swallows the upper lines.
  void paint(Canvas canvas, double height) {
    final top = origin.dy + height - fieldHeight;
    canvas
      ..save()
      ..clipRect(
        Rect.fromLTRB(
          origin.dx - 4,
          origin.dy - 4,
          origin.dx + size.width + 4,
          top + size.height + 4,
        ),
      )
      ..translate(origin.dx, top)
      ..save()
      // Whole columns, through the first released: its particles thin as
      // some wander left over the picture.
      ..clipRect(
        Rect.fromLTRB(
          0,
          0,
          math.min(_sweep.ceilToDouble() + 1, size.width),
          size.height,
        ),
      )
      ..drawPicture(picture)
      ..restore();
    if (_live > 0) {
      canvas.drawRawAtlas(
        _dot,
        Float32List.sublistView(_transforms, 0, _live * 4),
        Float32List.sublistView(_rects, 0, _live * 4),
        Int32List.sublistView(_colors, 0, _live),
        BlendMode.modulate,
        null,
        _paint,
      );
    }
    canvas.restore();
  }

  @override
  void dispose() {
    _disposed = true;
    picture.dispose();
    super.dispose();
  }
}

class _VanishPainter extends CustomPainter {
  _VanishPainter(this.vanishing) : super(repaint: vanishing);

  final _Vanishing vanishing;

  @override
  void paint(Canvas canvas, Size size) => vanishing.paint(canvas, size.height);

  @override
  bool shouldRepaint(_VanishPainter oldDelegate) =>
      oldDelegate.vanishing != vanishing;
}

/// The first text under [root], depth first.
RenderEditable? findEditable(RenderObject root) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  root.visitChildren(visit);
  return found;
}

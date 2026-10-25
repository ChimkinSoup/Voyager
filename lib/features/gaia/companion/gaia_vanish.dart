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
class GaiaVanish extends StatefulWidget {
  const GaiaVanish({
    super.key,
    required this.controller,
    required this.builder,
  });

  final TextEditingController controller;

  /// Builds the text field. While [vanishing], the field should expand to
  /// the height it's given (it closes smoothly once the text has been
  /// swept), align its text to the top and hide its hint.
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

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.controller.addListener(_onEdit);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEdit);
    _ticker.dispose();
    _vanishing?.dispose();
    _height.dispose();
    super.dispose();
  }

  /// Snapshots the field's text as laid out on screen. Call just before
  /// clearing the field.
  void vanish() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    final box = context.findRenderObject()! as RenderBox;
    final editable = _findEditable(box)!;
    _clear();
    final vanishing = _Vanishing.capture(editable, box);
    _height.value = vanishing.fieldHeight;
    setState(() {
      _vanishing = vanishing;
      _fading = false;
    });
    vanishing.sample().then((_) {
      if (mounted && identical(_vanishing, vanishing)) _ticker.start();
    });
  }

  void _tick(Duration elapsed) {
    final vanishing = _vanishing!;
    final particles = vanishing.advance(elapsed);
    if (!vanishing.swept) return;
    // Close the field to one line while the last particles settle.
    _closingFrom ??= elapsed;
    final t = math.min(
      1.0,
      (elapsed - _closingFrom!).inMicroseconds / _closing.inMicroseconds,
    );
    _height.value = ui.lerpDouble(
      vanishing.fieldHeight,
      vanishing.oneLineHeight,
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
    if (_vanishing != null && !_fading && widget.controller.text.isNotEmpty) {
      setState(() => _fading = true);
    }
  }

  static RenderEditable? _findEditable(RenderObject root) {
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

  @override
  Widget build(BuildContext context) {
    final vanishing = _vanishing;
    return Stack(
      children: [
        ValueListenableBuilder(
          valueListenable: _height,
          builder: (context, height, field) =>
              SizedBox(height: height, child: field),
          child: widget.builder(context, vanishing != null),
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
    this.oneLineHeight,
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

  /// Where the text's viewport sat in the field when sent.
  final Offset origin;
  final Size size;

  /// The text as it looked, drawn left of the sweep until it dissolves.
  final ui.Picture picture;

  /// The field's height when sent, and when holding a single empty line.
  final double fieldHeight;
  final double oneLineHeight;

  /// Whether the sweep has released every particle.
  bool get swept => _next == _count;

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

    final right = count == 0 ? 0.0 : _sourceX[0] + 1;
    _sweep = right;
    // 8px a step like the original, but never longer than ~0.75s a sweep.
    _speed = math.max(8, right / 45);
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
    var kept = 0;
    for (var i = 0; i < _live; i++) {
      final bits = _random.nextInt(1 << 20);
      final radius = _radius[i] - 0.05 * (bits >> 2) / (1 << 18);
      if (radius <= 0) continue;
      final from = i * 4;
      final to = kept * 4;
      _transforms[to + 2] = _transforms[from + 2] + (bits & 1) * 2 - 1;
      _transforms[to + 3] = _transforms[from + 3] + (bits & 2) - 1;
      _radius[kept] = radius;
      _alpha[kept] = _alpha[i];
      _rgb[kept] = _rgb[i];
      _colors[kept] = (_alpha[i] * radius * 255).round() << 24 | _rgb[i];
      kept++;
    }
    for (; _next < _count && _sourceX[_next] >= _sweep; _next++) {
      final to = kept * 4;
      _transforms[to + 2] = _sourceX[_next];
      _transforms[to + 3] = _sourceY[_next];
      _radius[kept] = 1;
      _alpha[kept] = _sourceAlpha[_next];
      _rgb[kept] = _sourceRgb[_next];
      _colors[kept] = (_alpha[kept] * 255).round() << 24 | _rgb[kept];
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
      ..clipRect(Rect.fromLTRB(0, 0, math.min(_sweep, size.width), size.height))
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

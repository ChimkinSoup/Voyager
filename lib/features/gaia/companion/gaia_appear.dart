import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// A sent message gathering out of particles in the chat: [GaiaVanish] run
/// backwards. Its [GaiaAppearPart]s are hidden while particles drift in and
/// settle on them, swept from left to right, each part drawn in behind the
/// sweep; once the last particle has settled, the parts themselves show.
class GaiaAppear extends StatefulWidget {
  const GaiaAppear({
    super.key,
    required this.play,
    this.ready,
    this.onDone,
    required this.child,
  });

  /// Whether to gather in. Read once, as it's first built.
  final bool play;

  /// What to wait for before the parts are captured, such as their images
  /// loading, so they're captured as they'll show. Without it, they're
  /// captured straight after their first frame.
  final Future<void> Function()? ready;

  /// Called once the parts show.
  final VoidCallback? onDone;

  final Widget child;

  @override
  State<GaiaAppear> createState() => _GaiaAppearState();
}

class _GaiaAppearState extends State<GaiaAppear>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late bool _hidden;
  _Gathering? _gathering;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _hidden = widget.play;
    if (_hidden) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    // Gone before it showed, as when its chat's left mid-gather: done all
    // the same, so it doesn't gather in again when it's back.
    if (_hidden && widget.onDone != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone!());
    }
    _ticker.dispose();
    _gathering?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) return _finish();
    // Without anything to wait for, the parts painted on the frame just
    // drawn. What's ready is built the frame after, and painted the one
    // after that.
    if (widget.ready case final ready?) {
      await ready();
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final _Gathering gathering;
    try {
      gathering = _capture();
      await gathering.sample();
    } catch (_) {
      // Not painted yet (built only in the list's cache, say), or not
      // readable: shown as it is rather than left hidden.
      if (mounted) _finish();
      return;
    }
    if (!mounted) return gathering.dispose();
    if (!gathering.inked) {
      gathering.dispose();
      return _finish();
    }
    setState(() => _gathering = gathering);
    _ticker.start();
  }

  /// Records every part as it's painted (hidden), where it sits in this.
  _Gathering _capture() {
    final box = context.findRenderObject()! as RenderBox;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    void visit(Element element) {
      if (element is StatefulElement && element.state is _GaiaAppearPartState) {
        final boundary =
            (element.state as _GaiaAppearPartState)._boundary.currentContext!
                    .findRenderObject()!
                as RenderRepaintBoundary;
        if (boundary.size.isEmpty) return;
        final image = boundary.toImageSync(pixelRatio: pixelRatio);
        canvas.drawImageRect(
          image,
          Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
          boundary.localToGlobal(Offset.zero, ancestor: box) & boundary.size,
          Paint()..filterQuality = FilterQuality.medium,
        );
        // The picture holds on to the image itself.
        image.dispose();
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return _Gathering(box.size, recorder.endRecording());
  }

  void _tick(Duration elapsed) {
    final gathering = _gathering!;
    if (!gathering.advance(elapsed)) _finish();
  }

  void _finish() {
    _ticker.stop();
    _gathering?.dispose();
    setState(() {
      _gathering = null;
      _hidden = false;
    });
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final gathering = _gathering;
    return Stack(
      // Laid out as if it weren't here, so a message keeps to its side.
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        _Hiding(hidden: _hidden, child: widget.child),
        if (gathering != null)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _GatherPainter(gathering)),
              ),
            ),
          ),
      ],
    );
  }
}

class _Hiding extends InheritedWidget {
  const _Hiding({required this.hidden, required super.child});

  final bool hidden;

  @override
  bool updateShouldNotify(_Hiding oldWidget) => hidden != oldWidget.hidden;
}

/// What a [GaiaAppear] gathers in, which it hides until the gathering's
/// done. Anything outside every part, such as a bubble's background, shows
/// throughout.
class GaiaAppearPart extends StatefulWidget {
  const GaiaAppearPart({super.key, required this.child});

  final Widget child;

  @override
  State<GaiaAppearPart> createState() => _GaiaAppearPartState();
}

class _GaiaAppearPartState extends State<GaiaAppearPart> {
  /// Keeps [GaiaAppearPart.child]'s state as it's hidden and shown.
  final _boundary = GlobalKey();

  /// Paints nothing, but still paints what's under it into its own layer,
  /// which the capture reads (an [Opacity] of 0 wouldn't paint it at all).
  static const _invisible = ColorFilter.mode(
    Color(0x00000000),
    BlendMode.dstIn,
  );

  @override
  Widget build(BuildContext context) {
    final boundary = RepaintBoundary(key: _boundary, child: widget.child);
    final hidden =
        context.dependOnInheritedWidgetOfExactType<_Hiding>()?.hidden ?? false;
    // Not clickable or selectable while it can't be seen.
    return hidden
        ? IgnorePointer(
            child: ColorFiltered(colorFilter: _invisible, child: boundary),
          )
        : boundary;
  }
}

/// The parts as particles, landing behind a sweep that crosses them from
/// left to right. Each lands as the sweep reaches it, after wandering in
/// for a lifetime like a vanished particle's, growing as it comes. Kept in
/// flat typed arrays and drawn in a single [Canvas.drawRawAtlas] call.
class _Gathering extends ChangeNotifier {
  _Gathering(this.size, this.picture);

  final Size size;

  /// The parts as captured, drawn left of the sweep once it's passed.
  final ui.Picture picture;

  // Pixels below this alpha are anti-aliasing fringe, not worth a particle.
  static const _minAlpha = 48;
  static const _stepsPerSecond = 60;

  /// How many steps a particle wanders in for, about a vanished one's.
  static const _minLife = 22;
  static const _maxLife = 36;

  /// How many steps the sweep starts before the first column.
  static const _leadIn = 12;

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

  // Every inked pixel, leftmost column first, so the sweep lets them in in
  // order from [_next].
  int _count = 0;
  int _next = 0;
  late Float32List _sourceX, _sourceY, _sourceAlpha;
  late Int32List _sourceRgb;

  // Particles let in, compacted into [0, _live): their pixel, the steps
  // until they land, how long they wander for, and how far off they are.
  int _live = 0;
  late Int32List _source, _remaining, _life, _dx, _dy, _colors;
  late Float32List _transforms, _rects;

  /// Where the sweep starts, and how far it moves a step.
  double _start = 0;
  double _speed = 0;
  int _steps = 0;

  bool get inked => _count > 0;

  /// Reads the picture back as pixels and lines them up to land.
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
    for (var x = 0; x < width; x++) {
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
    if (count == 0) return;

    _source = Int32List(count);
    _remaining = Int32List(count);
    _life = Int32List(count);
    _dx = Int32List(count);
    _dy = Int32List(count);
    _colors = Int32List(count);
    _transforms = Float32List(count * 4);
    _rects = Float32List(count * 4);
    for (var i = 0; i < count; i++) {
      _transforms[i * 4] = 1; // scale 1, no rotation
      _rects[i * 4 + 2] = 1;
      _rects[i * 4 + 3] = 1;
    }

    final left = _sourceX[0];
    final right = _sourceX[count - 1] + 1;
    // As fast as a vanishing's sweep, starting [_leadIn] steps early: the
    // first columns' particles show at once, already partway in.
    _speed = math.max(8.0, (right - left) / 45);
    _start = left - _leadIn * _speed;
  }

  /// The step on which pixel [i] lands: the first with its column wholly
  /// left of the sweep.
  int _landing(int i) => ((_sourceX[i] + 1 - _start) / _speed).ceil();

  /// Runs the fixed-rate steps due by [elapsed]. False once all have landed.
  bool advance(Duration elapsed) {
    final owed =
        elapsed.inMicroseconds *
        _stepsPerSecond ~/
        Duration.microsecondsPerSecond;
    // At most a few at once, so a slow frame doesn't skip them in a burst.
    final due = math.min(owed, _steps + 4);
    // Repainted only when something's moved, not on every frame of a fast
    // display.
    if (_steps < due) {
      for (; _steps < due; _steps++) {
        _step();
      }
      notifyListeners();
    }
    return _live > 0 || _next < _count;
  }

  void _step() {
    final step = _steps + 1;
    // Let in a lifetime before they land; hidden until their own is up.
    for (; _next < _count && _landing(_next) - _maxLife <= step; _next++) {
      final life = _minLife + _random.nextInt(_maxLife - _minLife + 1);
      final remaining = _landing(_next) - step + 1;
      // About as far as a vanished particle wanders in the steps it has.
      final spread = math.sqrt(math.min(life, remaining) * 4 / 3);
      _source[_live] = _next;
      _remaining[_live] = remaining;
      _life[_live] = life;
      _dx[_live] = (_spread() * spread).round();
      _dy[_live] = (_spread() * spread).round();
      _live++;
    }
    var kept = 0;
    for (var i = 0; i < _live; i++) {
      final remaining = _remaining[i] - 1;
      // Landed: the picture shows it now.
      if (remaining <= 0) continue;
      final life = _life[i];
      var dx = _dx[i], dy = _dy[i], color = 0;
      final source = _source[i];
      if (remaining <= life) {
        // Homing in, with a wander of -1, 0 or 1 each way from one draw.
        final bits = _random.nextInt(9);
        dx += (-dx / (remaining + 1)).round() + bits % 3 - 1;
        dy += (-dy / (remaining + 1)).round() + bits ~/ 3 - 1;
        final radius = 1 - remaining / (life + 1);
        color =
            (_sourceAlpha[source] * radius * 255).round() << 24 |
            _sourceRgb[source];
      }
      final to = kept * 4;
      _transforms[to + 2] = _sourceX[source] + dx;
      _transforms[to + 3] = _sourceY[source] + dy;
      _source[kept] = source;
      _remaining[kept] = remaining;
      _life[kept] = life;
      _dx[kept] = dx;
      _dy[kept] = dy;
      _colors[kept] = color;
      kept++;
    }
    _live = kept;
  }

  /// Roughly normal, from -3 to 3 with a spread of 1.
  double _spread() =>
      (_random.nextDouble() +
          _random.nextDouble() +
          _random.nextDouble() -
          1.5) *
      2;

  void paint(Canvas canvas) {
    canvas
      ..save()
      ..clipRect(
        Rect.fromLTRB(
          0,
          0,
          (_start + _steps * _speed).floorToDouble().clamp(0.0, size.width),
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
  }

  @override
  void dispose() {
    _disposed = true;
    picture.dispose();
    super.dispose();
  }
}

class _GatherPainter extends CustomPainter {
  _GatherPainter(this.gathering) : super(repaint: gathering);

  final _Gathering gathering;

  @override
  void paint(Canvas canvas, Size size) => gathering.paint(canvas);

  @override
  bool shouldRepaint(_GatherPainter oldDelegate) =>
      oldDelegate.gathering != gathering;
}

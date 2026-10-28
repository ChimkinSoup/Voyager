import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';

/// Opens the annotation editor (GAIA_HLD.md §9.4) on the image at [path],
/// starting from [edits]. Returns the edits as the user left them, or null
/// when they cancelled. Everything is drawn as marks over the untouched
/// original, flattened only when the message is sent.
Future<GaiaImageEdits?> showGaiaImageEditor(
  BuildContext context, {
  required String path,
  required int label,
  required GaiaImageEdits edits,
}) => showDialog<GaiaImageEdits>(
  context: context,
  builder: (context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    clipBehavior: Clip.antiAlias,
    child: _Editor(path: path, label: label, edits: edits),
  ),
);

/// What a tool draws in, before it's picked.
const _colors = [
  Color(0xFFFF3B30),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF0A84FF),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
];

const _toolIcons = {
  GaiaTool.pen: (Icons.edit_outlined, 'Pen'),
  GaiaTool.highlighter: (Icons.border_color_outlined, 'Highlighter'),
  GaiaTool.line: (Icons.horizontal_rule, 'Line'),
  GaiaTool.arrow: (Icons.north_east, 'Arrow'),
  GaiaTool.rectangle: (Icons.crop_square, 'Rectangle'),
  GaiaTool.ellipse: (Icons.circle_outlined, 'Ellipse'),
  GaiaTool.blur: (Icons.blur_on, 'Blur'),
  GaiaTool.redact: (Icons.rectangle, 'Redact'),
};

class _Editor extends StatefulWidget {
  const _Editor({required this.path, required this.label, required this.edits});

  final String path;
  final int label;
  final GaiaImageEdits edits;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  ui.Image? _image;

  /// Every state the edits have been in, and the one showing: undo and
  /// redo move along it.
  late final _history = [widget.edits];
  var _at = 0;

  /// Null for the crop tool.
  GaiaTool? _tool = GaiaTool.pen;

  /// Whether the move tool is picked instead: drags then move marks, and
  /// draw nothing.
  var _moveTool = false;
  var _color = _colors.first;

  /// Thin, medium or thick.
  var _weight = 1;

  /// The mark or crop being dragged out.
  GaiaMark? _drawing;
  Rect? _cropping;

  /// Where the drag began, and where the pointer is now before any Shift
  /// snapping: pressing or letting go of Shift re-snaps from them.
  Offset? _from;
  Offset? _pointer;

  /// While Shift is held on a pen or highlighter stroke, how many of its
  /// points came before: after them runs one straight line.
  int? _straightAt;

  /// The mark being dragged somewhere else, and the edits with it there.
  int? _grabbed;
  GaiaImageEdits? _moved;

  GaiaImageEdits get _edits => _history[_at];

  @override
  void initState() {
    super.initState();
    gaiaDecodeImage(widget.path).then((image) {
      if (!mounted) return image.dispose();
      setState(() => _image = image);
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _push(GaiaImageEdits edits) => setState(() {
    _history
      ..removeRange(_at + 1, _history.length)
      ..add(edits);
    _at = _history.length - 1;
  });

  void _undo() {
    if (_at > 0) setState(() => _at--);
  }

  void _redo() {
    if (_at < _history.length - 1) setState(() => _at++);
  }

  /// A stroke's width in the image's pixels, so it looks the same however
  /// big the image is.
  double _width(ui.Image image, GaiaTool tool) {
    final base = max(image.width, image.height) / 500;
    final width = base * const [1.5, 3.0, 6.0][_weight];
    return tool == GaiaTool.highlighter ? width * 4 : width;
  }

  /// With Shift held, lines (and the pen's and highlighter's straight runs)
  /// keep to 45° steps, and boxes, ellipses and crops to squares.
  Offset _snapped(Offset from, Offset to) {
    if (!HardwareKeyboard.instance.isShiftPressed) return to;
    final delta = to - from;
    switch (_tool) {
      case GaiaTool.line ||
          GaiaTool.arrow ||
          GaiaTool.pen ||
          GaiaTool.highlighter:
        const step = pi / 4;
        final angle = (delta.direction / step).roundToDouble() * step;
        return from + Offset.fromDirection(angle, delta.distance);
      default:
        final side = max(delta.dx.abs(), delta.dy.abs());
        return from +
            Offset(delta.dx < 0 ? -side : side, delta.dy < 0 ? -side : side);
    }
  }

  void _start(Offset point) {
    final image = _image!;
    _from = point;
    _pointer = point;
    setState(() {
      final tool = _tool;
      if (tool == null) {
        _cropping = Rect.fromPoints(point, point);
        return;
      }
      _drawing = GaiaMark(
        tool: tool,
        points: [point],
        color: _color,
        width: _width(image, tool),
      );
    });
  }

  void _grab(int index, Offset point) {
    _from = point;
    _grabbed = index;
  }

  void _move(Offset point) => setState(() {
    final from = _from!;
    _pointer = point;
    if (_grabbed case final index?) {
      final marks = [..._edits.marks];
      marks[index] = marks[index].movedBy(point - from);
      _moved = GaiaImageEdits(marks: marks, crop: _edits.crop);
    } else if (_cropping != null) {
      _cropping = Rect.fromPoints(from, _snapped(from, point));
    } else if (_drawing case final mark?
        when mark.tool == GaiaTool.pen || mark.tool == GaiaTool.highlighter) {
      if (!HardwareKeyboard.instance.isShiftPressed) {
        _straightAt = null;
        _drawing = mark.withPoint(point);
        return;
      }
      // A straight line on from where the stroke was when Shift went down.
      final kept = mark.points.take(_straightAt ??= mark.points.length);
      _drawing = GaiaMark(
        tool: mark.tool,
        points: [...kept, _snapped(kept.last, point)],
        color: mark.color,
        width: mark.width,
      );
    } else {
      _drawing = _drawing?.withPoint(_snapped(from, point));
    }
  });

  void _end() {
    final image = _image!;
    _from = null;
    _pointer = null;
    _straightAt = null;
    final full =
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
    if (_grabbed != null) {
      final moved = _moved;
      _grabbed = null;
      _moved = null;
      if (moved == null) return setState(() {});
      _push(moved);
      return;
    }
    if (_cropping case final crop?) {
      _cropping = null;
      final area = crop.intersect(full);
      // A click doesn't crop to nothing.
      if (area.width < 4 || area.height < 4) return setState(() {});
      _push(GaiaImageEdits(marks: _edits.marks, crop: area));
      return;
    }
    final mark = _drawing;
    _drawing = null;
    if (mark == null) return;
    _push(GaiaImageEdits(marks: [..._edits.marks, mark], crop: _edits.crop));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = _image;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): _redo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            Navigator.of(context).pop(_edits),
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event.logicalKey
              case LogicalKeyboardKey.shiftLeft || LogicalKeyboardKey.shiftRight
              when event is! KeyRepeatEvent && _pointer != null) {
            _move(_pointer!);
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  Text(
                    gaiaImageToken(widget.label),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(width: 12),
                  // Wrapped, not scrolled: a mouse wheel can't scroll
                  // sideways to tools out of view.
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _ToolButton(
                          icon: Icons.open_with,
                          tooltip: 'Move',
                          selected: _moveTool,
                          onPressed: () => setState(() => _moveTool = true),
                        ),
                        for (final MapEntry(key: tool, value: (icon, name))
                            in _toolIcons.entries)
                          _ToolButton(
                            icon: icon,
                            tooltip: name,
                            selected: !_moveTool && _tool == tool,
                            onPressed: () => setState(() {
                              _moveTool = false;
                              _tool = tool;
                            }),
                          ),
                        _ToolButton(
                          icon: Icons.crop,
                          tooltip: 'Crop',
                          selected: !_moveTool && _tool == null,
                          onPressed: () => setState(() {
                            _moveTool = false;
                            _tool = null;
                          }),
                        ),
                        const SizedBox(width: 8),
                        for (final color in _colors)
                          _Swatch(
                            color: color,
                            selected: color == _color,
                            onPressed: () => setState(() => _color = color),
                          ),
                        const SizedBox(width: 8),
                        for (final (i, name) in const [
                          'Thin',
                          'Medium',
                          'Thick',
                        ].indexed)
                          _ToolButton(
                            icon: Icons.circle,
                            iconSize: 6.0 + i * 4,
                            tooltip: name,
                            selected: _weight == i,
                            onPressed: () => setState(() => _weight = i),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Beside the buttons, where they stay put as tools wrap.
                  _ToolButton(
                    icon: Icons.undo,
                    tooltip: 'Undo (Ctrl+Z)',
                    onPressed: _at > 0 ? _undo : null,
                  ),
                  _ToolButton(
                    icon: Icons.redo,
                    tooltip: 'Redo (Ctrl+Y)',
                    onPressed: _at < _history.length - 1 ? _redo : null,
                  ),
                  const SizedBox(width: 8),
                  GaiaButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  GaiaButton(
                    label: 'Done',
                    onPressed: () => Navigator.of(context).pop(_edits),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: image == null
                  ? const Center(child: GaiaSpinner(size: 48))
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: _Canvas(
                        image: image,
                        edits: _moved ?? _edits,
                        drawing: _drawing,
                        cropping: _cropping,
                        moveTool: _moveTool,
                        onGrab: _grab,
                        onStart: _start,
                        onMove: _move,
                        onEnd: _end,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The image fitted to the space, with the edits over it. Pointer
/// positions go out in the image's pixels. With [moveTool], a drag that
/// starts on a mark moves it, and one that doesn't does nothing.
class _Canvas extends StatefulWidget {
  const _Canvas({
    required this.image,
    required this.edits,
    required this.drawing,
    required this.cropping,
    required this.moveTool,
    required this.onGrab,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
  });

  final ui.Image image;
  final GaiaImageEdits edits;
  final GaiaMark? drawing;
  final Rect? cropping;
  final bool moveTool;
  final void Function(int mark, Offset point) onGrab;
  final void Function(Offset point) onStart;
  final void Function(Offset point) onMove;
  final VoidCallback onEnd;

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> {
  /// Whether the pointer is over a mark, so a drag would move it.
  var _overMark = false;

  /// Whether the drag going on draws or moves anything.
  var _dragging = false;

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final scale = min(size.width / image.width, size.height / image.height);
        final offset = Offset(
          (size.width - image.width * scale) / 2,
          (size.height - image.height * scale) / 2,
        );
        Offset toImage(Offset local) => (local - offset) / scale;
        // A few screen pixels' leeway, however far the image is scaled.
        int? markAt(Offset local) =>
            _markAt(widget.edits.marks, toImage(local), 6 / scale);
        return MouseRegion(
          cursor: !widget.moveTool
              ? SystemMouseCursors.precise
              : _overMark
              ? SystemMouseCursors.move
              : SystemMouseCursors.basic,
          onHover: (event) {
            if (!widget.moveTool) return;
            final over = markAt(event.localPosition) != null;
            if (over != _overMark) setState(() => _overMark = over);
          },
          child: GestureDetector(
            onPanStart: (details) {
              final point = toImage(details.localPosition);
              _dragging = true;
              if (!widget.moveTool) {
                widget.onStart(point);
              } else if (markAt(details.localPosition) case final mark?) {
                widget.onGrab(mark, point);
              } else {
                _dragging = false;
              }
            },
            onPanUpdate: (details) {
              if (_dragging) widget.onMove(toImage(details.localPosition));
            },
            onPanEnd: (_) {
              if (_dragging) widget.onEnd();
              _dragging = false;
            },
            child: CustomPaint(
              size: size,
              painter: _EditsPainter(
                image: image,
                edits: widget.edits,
                drawing: widget.drawing,
                cropping: widget.cropping,
                scale: scale,
                offset: offset,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The topmost of [marks] within [slop] of [point]: on a stroke or an
/// outline, or anywhere inside a blur or redaction.
int? _markAt(List<GaiaMark> marks, Offset point, double slop) {
  bool inOval(Rect oval) {
    if (oval.width <= 0 || oval.height <= 0) return false;
    final d = point - oval.center;
    return pow(d.dx / (oval.width / 2), 2) + pow(d.dy / (oval.height / 2), 2) <=
        1;
  }

  for (var i = marks.length - 1; i >= 0; i--) {
    final mark = marks[i];
    final reach = slop + mark.width / 2;
    final bounds = mark.bounds;
    final hit = switch (mark.tool) {
      GaiaTool.blur || GaiaTool.redact => bounds.inflate(slop).contains(point),
      GaiaTool.rectangle =>
        bounds.inflate(reach).contains(point) &&
            !bounds.deflate(reach).contains(point),
      GaiaTool.ellipse =>
        inOval(bounds.inflate(reach)) && !inOval(bounds.deflate(reach)),
      GaiaTool.pen ||
      GaiaTool.highlighter ||
      GaiaTool.line ||
      GaiaTool.arrow => [
        for (var j = 0; j < max(1, mark.points.length - 1); j++)
          _toSegment(
            point,
            mark.points[j],
            mark.points[min(j + 1, mark.points.length - 1)],
          ),
      ].any((distance) => distance <= reach),
    };
    if (hit) return i;
  }
  return null;
}

/// How far [point] is from the segment [a] to [b].
double _toSegment(Offset point, Offset a, Offset b) {
  final ab = b - a;
  final length = ab.distanceSquared;
  if (length == 0) return (point - a).distance;
  final ap = point - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / length).clamp(0.0, 1.0);
  return (point - (a + ab * t)).distance;
}

class _EditsPainter extends CustomPainter {
  const _EditsPainter({
    required this.image,
    required this.edits,
    required this.drawing,
    required this.cropping,
    required this.scale,
    required this.offset,
  });

  final ui.Image image;
  final GaiaImageEdits edits;
  final GaiaMark? drawing;
  final Rect? cropping;
  final double scale;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    final full =
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..scale(scale)
      ..clipRect(full)
      ..drawImage(
        image,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.medium,
      );
    gaiaPaintMarks(canvas, image, [...edits.marks, ?drawing]);
    // Outside the crop dims, so what's kept stands out.
    final crop = cropping ?? edits.crop;
    if (crop != null) {
      canvas
        ..drawPath(
          Path.combine(
            PathOperation.difference,
            Path()..addRect(full),
            Path()..addRect(crop),
          ),
          Paint()..color = Colors.black.withValues(alpha: 0.55),
        )
        ..drawRect(
          crop,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / scale,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EditsPainter old) =>
      old.image != image ||
      old.edits != edits ||
      old.drawing != drawing ||
      old.cropping != cropping ||
      old.scale != scale ||
      old.offset != offset;
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.iconSize = 20,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      iconSize: iconSize,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
            : null,
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white24,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

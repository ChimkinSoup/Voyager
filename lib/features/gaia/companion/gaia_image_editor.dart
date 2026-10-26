import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';

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
  GaiaTool? _tool = GaiaTool.arrow;
  var _color = _colors.first;

  /// Thin, medium or thick.
  var _weight = 1;

  /// The mark or crop being dragged out.
  GaiaMark? _drawing;
  Rect? _cropping;

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

  void _start(Offset point) {
    final image = _image!;
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

  void _move(Offset point) => setState(() {
    if (_cropping case final crop?) {
      _cropping = Rect.fromPoints(crop.topLeft, point);
    } else {
      _drawing = _drawing?.withPoint(point);
    }
  });

  void _end() {
    final image = _image!;
    final full =
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
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
                        for (final MapEntry(key: tool, value: (icon, name))
                            in _toolIcons.entries)
                          _ToolButton(
                            icon: icon,
                            tooltip: name,
                            selected: _tool == tool,
                            onPressed: () => setState(() => _tool = tool),
                          ),
                        _ToolButton(
                          icon: Icons.crop,
                          tooltip: 'Crop',
                          selected: _tool == null,
                          onPressed: () => setState(() => _tool = null),
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
                  ? const Center(child: CircularProgressIndicator())
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: _Canvas(
                        image: image,
                        edits: _edits,
                        drawing: _drawing,
                        cropping: _cropping,
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
/// positions go out in the image's pixels.
class _Canvas extends StatelessWidget {
  const _Canvas({
    required this.image,
    required this.edits,
    required this.drawing,
    required this.cropping,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
  });

  final ui.Image image;
  final GaiaImageEdits edits;
  final GaiaMark? drawing;
  final Rect? cropping;
  final void Function(Offset point) onStart;
  final void Function(Offset point) onMove;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final scale = min(size.width / image.width, size.height / image.height);
        final offset = Offset(
          (size.width - image.width * scale) / 2,
          (size.height - image.height * scale) / 2,
        );
        Offset toImage(Offset local) => (local - offset) / scale;
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            onPanStart: (details) => onStart(toImage(details.localPosition)),
            onPanUpdate: (details) => onMove(toImage(details.localPosition)),
            onPanEnd: (_) => onEnd(),
            child: CustomPaint(
              size: size,
              painter: _EditsPainter(
                image: image,
                edits: edits,
                drawing: drawing,
                cropping: cropping,
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

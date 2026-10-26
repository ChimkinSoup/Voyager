import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

/// The annotation editor's tools (GAIA_HLD.md §9.4).
enum GaiaTool {
  pen,
  highlighter,
  line,
  arrow,
  rectangle,
  ellipse,
  blur,
  redact,
}

/// One drawn mark, in the image's own pixels: a stroke through [points]
/// for the pen and highlighter, or a shape from the first point to the
/// last for the rest.
class GaiaMark {
  const GaiaMark({
    required this.tool,
    required this.points,
    required this.color,
    required this.width,
  });

  final GaiaTool tool;
  final List<Offset> points;
  final Color color;
  final double width;

  Rect get bounds => Rect.fromPoints(points.first, points.last);

  GaiaMark withPoint(Offset point) => GaiaMark(
    tool: tool,
    points: switch (tool) {
      GaiaTool.pen || GaiaTool.highlighter => [...points, point],
      _ => [points.first, point],
    },
    color: color,
    width: width,
  );
}

/// What the editor did to an image: its marks, oldest first, and a crop in
/// the image's pixels. The original stays as it was, so it can be edited
/// again.
class GaiaImageEdits {
  const GaiaImageEdits({this.marks = const [], this.crop});

  static const none = GaiaImageEdits();

  final List<GaiaMark> marks;
  final Rect? crop;

  bool get isEmpty => marks.isEmpty && crop == null;
}

/// Paints [marks] over [image], drawn at its own size on [canvas].
void gaiaPaintMarks(Canvas canvas, ui.Image image, List<GaiaMark> marks) {
  for (final mark in marks) {
    final paint = Paint()
      ..color = mark.color
      ..strokeWidth = mark.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final bounds = mark.bounds;
    switch (mark.tool) {
      case GaiaTool.pen:
        canvas.drawPath(_through(mark.points), paint);
      case GaiaTool.highlighter:
        // Multiplied, so the text under it stays readable.
        canvas.drawPath(
          _through(mark.points),
          paint
            ..blendMode = BlendMode.multiply
            ..strokeCap = StrokeCap.square,
        );
      case GaiaTool.line:
        canvas.drawLine(mark.points.first, mark.points.last, paint);
      case GaiaTool.arrow:
        _arrow(canvas, mark.points.first, mark.points.last, paint);
      case GaiaTool.rectangle:
        canvas.drawRect(bounds, paint);
      case GaiaTool.ellipse:
        canvas.drawOval(bounds, paint);
      case GaiaTool.blur:
        canvas
          ..save()
          ..clipRect(bounds)
          ..saveLayer(
            bounds,
            // Clamped: a box smaller than the blur would otherwise go
            // see-through, and show the sharp image under it.
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: 12,
                sigmaY: 12,
                tileMode: TileMode.clamp,
              ),
          )
          ..drawImage(image, Offset.zero, Paint())
          ..restore()
          ..restore();
      case GaiaTool.redact:
        // Solid, unlike a blur: nothing of what's under it survives.
        canvas.drawRect(bounds, Paint()..color = const Color(0xFF000000));
    }
  }
}

Path _through(List<Offset> points) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final point in points.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  // A dot for a click.
  if (points.length == 1) path.lineTo(points.first.dx, points.first.dy);
  return path;
}

void _arrow(Canvas canvas, Offset from, Offset to, Paint paint) {
  canvas.drawLine(from, to, paint);
  final delta = to - from;
  if (delta.distance == 0) return;
  final head = paint.strokeWidth * 4;
  final back = -delta / delta.distance * head;
  // Two barbs, half a radian either side of the shaft.
  for (final turn in [0.5, -0.5]) {
    final c = math.cos(turn);
    final s = math.sin(turn);
    canvas.drawLine(
      to,
      to + Offset(back.dx * c - back.dy * s, back.dx * s + back.dy * c),
      paint,
    );
  }
}

Future<ui.Image> gaiaDecodeImage(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// The image at [path] with [edits] applied, as a PNG.
Future<Uint8List> gaiaRenderPng(
  String path, {
  Rect? crop,
  GaiaImageEdits edits = GaiaImageEdits.none,
}) async {
  final image = await gaiaDecodeImage(path);
  final full =
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
  final area = (crop ?? edits.crop ?? full).intersect(full);
  final width = area.width.round().clamp(1, image.width);
  final height = area.height.round().clamp(1, image.height);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..translate(-area.left, -area.top)
    ..drawImage(image, Offset.zero, Paint());
  gaiaPaintMarks(canvas, image, edits.marks);
  final out = await recorder.endRecording().toImage(width, height);
  try {
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    out.dispose();
    image.dispose();
  }
}

/// A file of [path]'s image the media module takes: [path] itself for a
/// PNG, JPEG or WebP without [edits], otherwise a PNG rendered beside it.
Future<String> gaiaUploadablePath(
  String path, {
  GaiaImageEdits edits = GaiaImageEdits.none,
}) async {
  if (edits.isEmpty && !await _isBmp(path)) return path;
  final png = File('${p.withoutExtension(path)}-upload.png');
  await png.writeAsBytes(await gaiaRenderPng(path, edits: edits));
  return png.path;
}

Future<bool> _isBmp(String path) async {
  final file = await File(path).open();
  try {
    final head = await file.read(2);
    return head.length == 2 && head[0] == 0x42 && head[1] == 0x4D;
  } finally {
    await file.close();
  }
}

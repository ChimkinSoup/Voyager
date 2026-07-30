import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A leaf/petal silhouette design, catalogued for the debug design gallery.
///
/// This is a fixed catalog for browsing, not a runtime switch: [PetalField]
/// (see `petal_field.dart`) always draws [petal] directly by name. Swapping
/// which design the live background uses is a manual code change, made one
/// design at a time on request.
enum LeafDesign {
  petal(
    number: 0,
    label: 'Petal (current)',
    pathBuilder: petalPath,
  ),
  ovalLeaf(
    number: 1,
    label: 'Oval Leaf',
    pathBuilder: ovalLeafPath,
    veinBuilder: ovalLeafVeins,
  ),
  mapleLeaf(
    number: 2,
    label: 'Maple Leaf',
    pathBuilder: mapleLeafPath,
    veinBuilder: mapleLeafVeins,
  ),
  ivyLeaf(
    number: 3,
    label: 'Ivy Leaf',
    pathBuilder: ivyLeafPath,
    veinBuilder: ivyLeafVeins,
  ),
  sakuraBlossom(
    number: 4,
    label: 'Sakura Blossom',
    pathBuilder: sakuraBlossomPath,
    veinBuilder: sakuraBlossomVeins,
  ),
  lotusBlossom(
    number: 5,
    label: 'Lotus Blossom',
    pathBuilder: lotusBlossomPath,
    veinBuilder: lotusBlossomVeins,
  ),
  plumeriaBlossom(
    number: 6,
    label: 'Plumeria Blossom',
    pathBuilder: plumeriaBlossomPath,
    veinBuilder: plumeriaBlossomVeins,
  ),
  wildRoseBlossom(
    number: 7,
    label: 'Wild Rose Blossom',
    pathBuilder: wildRoseBlossomPath,
    veinBuilder: wildRoseBlossomVeins,
  ),
  sunflowerBlossom(
    number: 8,
    label: 'Sunflower Blossom',
    pathBuilder: sunflowerBlossomPath,
    veinBuilder: sunflowerBlossomVeins,
  ),
  tulipBlossom(
    number: 9,
    label: 'Tulip Blossom',
    pathBuilder: tulipBlossomPath,
    veinBuilder: tulipBlossomVeins,
  ),
  raindropPetal(
    number: 10,
    label: 'Raindrop Petal',
    pathBuilder: raindropPetalPath,
  ),
  watercolorPetal(
    number: 11,
    label: 'Watercolor Petal',
    pathBuilder: petalPath,
    customPainter: paintWatercolorPetal,
  );

  const LeafDesign({
    required this.number,
    required this.label,
    required this.pathBuilder,
    this.veinBuilder,
    this.customPainter,
  });

  /// Stable index shown in the debug gallery. Not tied to enum declaration
  /// order in code, so new entries can be inserted without relabeling old
  /// ones.
  final int number;

  final String label;

  /// Silhouette inscribed in a given rect.
  final Path Function(Rect rect) pathBuilder;

  /// Optional vein strokes, drawn over the filled silhouette. Null for
  /// [petal], which has never had veins and shouldn't grow them as a side
  /// effect of this catalog existing.
  final Path Function(Rect rect)? veinBuilder;

  /// Optional custom watercolor wash painter for designs with specialized multi-layered rendering.
  final void Function(Canvas canvas, Path path, Rect rect, Color color)? customPainter;
}

/// Paints [design] filled with a watercolor wash of [color] inside [rect]:
/// a soft-edged gradient plus a blurred restatement of the silhouette for a
/// soft outline, and (if the design has one) a subtle vein overlay.
///
/// Shared by the live [PetalField] sprite (rasterized once and stamped many
/// times, see `petal_field.dart`) and the debug design gallery (painted
/// directly, since a handful of static previews don't need the sprite-cache
/// optimization) so both draw the exact same technique.
void paintLeaf(Canvas canvas, LeafDesign design, Rect rect, Color color) {
  final path = design.pathBuilder(rect);

  if (design.customPainter != null) {
    design.customPainter!(canvas, path, rect, color);
    return;
  }

  // Watercolor reads as pigment pooling unevenly: denser along one edge,
  // washing out toward the tip. A linear gradient across the shape plus a
  // slightly brighter core does that far more cheaply than any real
  // diffusion.
  final gradient = ui.Gradient.linear(
    Offset(rect.left + rect.width * 0.30, rect.top),
    Offset(rect.right, rect.bottom),
    [
      Color.lerp(color, Colors.white, 0.42)!.withValues(alpha: 0.92),
      color.withValues(alpha: 0.95),
      Color.lerp(color, const Color(0xFF7C4A57), 0.28)!.withValues(alpha: 0.78),
    ],
    const [0.0, 0.55, 1.0],
  );

  canvas.drawPath(
    path,
    Paint()
      ..shader = gradient
      ..isAntiAlias = true,
  );

  // A faint blurred restatement of the same silhouette softens the outline
  // so the shape sits in the paper rather than being cut out of it.
  canvas.drawPath(
    path,
    Paint()
      ..color = color.withValues(alpha: 0.35)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3.0),
  );

  final veinBuilder = design.veinBuilder;
  if (veinBuilder != null) {
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(
      veinBuilder(rect),
      Paint()
        ..color = Color.lerp(color, const Color(0xFF4A2E36), 0.55)!
            .withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = rect.shortestSide * 0.012
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    canvas.restore();
  }
}

/// Rasterizes [design] into a small square image filled with [color], fully
/// opaque at its densest so per-instance opacity can be applied cheaply at
/// draw time. See [paintLeaf] for the actual drawing technique.
ui.Image buildLeafSprite(LeafDesign design, Color color, {double extent = 96.0}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paintLeaf(canvas, design, Rect.fromLTWH(0, 0, extent, extent), color);
  return recorder.endRecording().toImageSync(extent.toInt(), extent.toInt());
}

/// The current background petal: pointed at the top, full and rounded at the
/// base, with a slight curl to one side so it never reads as a symmetrical
/// leaf.
Path petalPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.04).dx, p(0.50, 0.04).dy)
    ..cubicTo(
      p(0.86, 0.22).dx, p(0.86, 0.22).dy,
      p(0.96, 0.64).dx, p(0.96, 0.64).dy,
      p(0.54, 0.96).dx, p(0.54, 0.96).dy,
    )
    ..cubicTo(
      p(0.14, 0.72).dx, p(0.14, 0.72).dy,
      p(0.06, 0.28).dx, p(0.06, 0.28).dy,
      p(0.50, 0.04).dx, p(0.50, 0.04).dy,
    )
    ..close();
}

/// A classic almond-shaped leaf: pointed at both ends, widest at the middle.
Path ovalLeafPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.03).dx, p(0.50, 0.03).dy)
    ..cubicTo(
      p(0.88, 0.18).dx, p(0.88, 0.18).dy,
      p(0.92, 0.55).dx, p(0.92, 0.55).dy,
      p(0.50, 0.97).dx, p(0.50, 0.97).dy,
    )
    ..cubicTo(
      p(0.08, 0.55).dx, p(0.08, 0.55).dy,
      p(0.12, 0.18).dx, p(0.12, 0.18).dy,
      p(0.50, 0.03).dx, p(0.50, 0.03).dy,
    )
    ..close();
}

/// A midrib down the center with a few side veins branching off it, safely
/// bounded within the leaf silhouette.
Path ovalLeafVeins(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  final path = Path()
    ..moveTo(p(0.50, 0.10).dx, p(0.50, 0.10).dy)
    ..quadraticBezierTo(
      p(0.54, 0.50).dx, p(0.54, 0.50).dy,
      p(0.50, 0.90).dx, p(0.50, 0.90).dy,
    );

  // Side veins (t, endRightX, endLeftX, endY) kept comfortably inside leaf bounds
  final veinSpecs = [
    (0.30, 0.68, 0.32, 0.38),
    (0.48, 0.72, 0.28, 0.58),
    (0.66, 0.64, 0.36, 0.74),
  ];

  for (final spec in veinSpecs) {
    final t = spec.$1;
    final rx = spec.$2;
    final lx = spec.$3;
    final endY = spec.$4;
    final from = p(0.51, t);
    path
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(p(rx - 0.04, t + 0.04).dx, p(rx - 0.04, t + 0.04).dy, p(rx, endY).dx, p(rx, endY).dy)
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(p(lx + 0.04, t + 0.04).dx, p(lx + 0.04, t + 0.04).dy, p(lx, endY).dx, p(lx, endY).dy);
  }
  return path;
}

/// A 5-lobed, rounded star silhouette elongated vertically to read as a
/// maple-style leaf.
Path mapleLeafPath(Rect rect) {
  return _roundedLobesPath(
    rect,
    lobes: 5,
    innerRadiusFrac: 0.40,
    outerRadiusFrac: 0.88,
    squashX: 0.95,
    squashY: 1.08,
  );
}

/// Short veins radiating from the center out to each lobe tip.
Path mapleLeafVeins(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2;
  const lobes = 5;

  final path = Path();
  for (var i = 0; i < lobes; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / lobes;
    final tip = Offset(
      cx + math.cos(angle) * baseR * 0.88 * 0.95,
      cy + math.sin(angle) * baseR * 0.88 * 1.08,
    );
    path
      ..moveTo(cx, cy)
      ..lineTo(tip.dx, tip.dy);
  }
  return path;
}

/// Builds a rounded, star-like polygon: [lobes] outer points alternating
/// with [lobes] inner points, with each vertex rounded off toward the
/// midpoint of its neighbouring edges. A robust way to get an organic,
/// self-intersection-free lobed silhouette (used for the maple leaf) without
/// hand-placing curve control points.
Path _roundedLobesPath(
  Rect rect, {
  required int lobes,
  required double innerRadiusFrac,
  required double outerRadiusFrac,
  double startAngle = -math.pi / 2,
  double squashX = 1.0,
  double squashY = 1.0,
}) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2;
  final n = lobes * 2;

  final points = <Offset>[];
  for (var i = 0; i < n; i++) {
    final angle = startAngle + i * math.pi / lobes;
    final r = (i.isEven ? outerRadiusFrac : innerRadiusFrac) * baseR;
    points.add(
      Offset(cx + math.cos(angle) * r * squashX, cy + math.sin(angle) * r * squashY),
    );
  }

  Offset mid(Offset a, Offset b) => Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

  final start = mid(points.last, points.first);
  final path = Path()..moveTo(start.dx, start.dy);
  for (var i = 0; i < n; i++) {
    final next = points[(i + 1) % n];
    final m = mid(points[i], next);
    path.quadraticBezierTo(points[i].dx, points[i].dy, m.dx, m.dy);
  }
  path.close();
  return path;
}

/// A heart-shaped leaf: two rounded lobes at the top meeting in a cleft,
/// tapering to a single point at the bottom. The two lobes are deliberately
/// not perfect mirrors of each other, in the same spirit as [petalPath]'s
/// curl, so it doesn't read as stamped.
Path ivyLeafPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.28).dx, p(0.50, 0.28).dy)
    ..cubicTo(
      p(0.50, 0.06).dx, p(0.50, 0.06).dy,
      p(0.82, 0.02).dx, p(0.82, 0.02).dy,
      p(0.94, 0.26).dx, p(0.94, 0.26).dy,
    )
    ..cubicTo(
      p(1.02, 0.46).dx, p(1.02, 0.46).dy,
      p(0.86, 0.58).dx, p(0.86, 0.58).dy,
      p(0.68, 0.72).dx, p(0.68, 0.72).dy,
    )
    ..cubicTo(
      p(0.58, 0.80).dx, p(0.58, 0.80).dy,
      p(0.52, 0.90).dx, p(0.52, 0.90).dy,
      p(0.50, 0.97).dx, p(0.50, 0.97).dy,
    )
    ..cubicTo(
      p(0.48, 0.90).dx, p(0.48, 0.90).dy,
      p(0.41, 0.79).dx, p(0.41, 0.79).dy,
      p(0.30, 0.71).dx, p(0.30, 0.71).dy,
    )
    ..cubicTo(
      p(0.13, 0.57).dx, p(0.13, 0.57).dy,
      p(-0.01, 0.44).dx, p(-0.01, 0.44).dy,
      p(0.08, 0.25).dx, p(0.08, 0.25).dy,
    )
    ..cubicTo(
      p(0.19, 0.02).dx, p(0.19, 0.02).dy,
      p(0.50, 0.06).dx, p(0.50, 0.06).dy,
      p(0.50, 0.28).dx, p(0.50, 0.28).dy,
    )
    ..close();
}

/// A center midrib plus two short pairs of side veins, one into each lobe.
Path ivyLeafVeins(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.30).dx, p(0.50, 0.30).dy)
    ..lineTo(p(0.50, 0.92).dx, p(0.50, 0.92).dy)
    ..moveTo(p(0.50, 0.45).dx, p(0.50, 0.45).dy)
    ..lineTo(p(0.78, 0.30).dx, p(0.78, 0.30).dy)
    ..moveTo(p(0.50, 0.45).dx, p(0.50, 0.45).dy)
    ..lineTo(p(0.22, 0.30).dx, p(0.22, 0.30).dy)
    ..moveTo(p(0.50, 0.65).dx, p(0.50, 0.65).dy)
    ..lineTo(p(0.68, 0.55).dx, p(0.68, 0.55).dy)
    ..moveTo(p(0.50, 0.65).dx, p(0.50, 0.65).dy)
    ..lineTo(p(0.32, 0.55).dx, p(0.32, 0.55).dy);
}

/// A 5-petal cherry blossom rosette with characteristic notched petal tips.
Path sakuraBlossomPath(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const petals = 5;

  final path = Path();
  for (var i = 0; i < petals; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / petals;

    Offset pt(double rFrac, double aOffset) {
      final a = angle + aOffset;
      final r = baseR * rFrac;
      return Offset(cx + math.cos(a) * r, cy + math.sin(a) * r);
    }

    final pBaseLeft = pt(0.12, -0.20);
    final pMidLeft = pt(0.60, -0.42);
    final pTipLeft = pt(0.92, -0.24);
    final pNotch = pt(0.72, 0.0);
    final pTipRight = pt(0.92, 0.24);
    final pMidRight = pt(0.60, 0.42);
    final pBaseRight = pt(0.12, 0.20);

    path.moveTo(pBaseLeft.dx, pBaseLeft.dy);
    path.cubicTo(
      pMidLeft.dx, pMidLeft.dy,
      pTipLeft.dx, pTipLeft.dy,
      pTipLeft.dx, pTipLeft.dy,
    );
    path.quadraticBezierTo(
      pNotch.dx, pNotch.dy,
      pTipRight.dx, pTipRight.dy,
    );
    path.cubicTo(
      pTipRight.dx, pTipRight.dy,
      pMidRight.dx, pMidRight.dy,
      pBaseRight.dx, pBaseRight.dy,
    );
    path.quadraticBezierTo(
      cx, cy,
      pBaseLeft.dx, pBaseLeft.dy,
    );
  }
  return path;
}

/// Central pistil hub with delicate radial stamens extending into each petal.
Path sakuraBlossomVeins(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const petals = 5;

  final path = Path();
  path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: baseR * 0.12));

  for (var i = 0; i < petals; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / petals;

    for (final aOff in [-0.15, 0.0, 0.15]) {
      final a = angle + aOff;
      final stamenTip = Offset(
        cx + math.cos(a) * baseR * 0.52,
        cy + math.sin(a) * baseR * 0.52,
      );
      final stamenBase = Offset(
        cx + math.cos(a) * baseR * 0.12,
        cy + math.sin(a) * baseR * 0.12,
      );
      path
        ..moveTo(stamenBase.dx, stamenBase.dy)
        ..lineTo(stamenTip.dx, stamenTip.dy)
        ..addOval(Rect.fromCircle(center: stamenTip, radius: baseR * 0.025));
    }
  }
  return path;
}

/// A layered Lotus / Water Lily blossom contour with sweeping side petals
/// and a towering central peak.
Path lotusBlossomPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.94).dx, p(0.50, 0.94).dy)
    ..cubicTo(
      p(0.68, 0.92).dx, p(0.68, 0.92).dy,
      p(0.94, 0.76).dx, p(0.94, 0.76).dy,
      p(0.96, 0.54).dx, p(0.96, 0.54).dy,
    )
    ..cubicTo(
      p(0.86, 0.44).dx, p(0.86, 0.44).dy,
      p(0.78, 0.32).dx, p(0.78, 0.32).dy,
      p(0.76, 0.22).dx, p(0.76, 0.22).dy,
    )
    ..quadraticBezierTo(
      p(0.66, 0.28).dx, p(0.66, 0.28).dy,
      p(0.64, 0.34).dx, p(0.64, 0.34).dy,
    )
    ..cubicTo(
      p(0.62, 0.16).dx, p(0.62, 0.16).dy,
      p(0.56, 0.05).dx, p(0.56, 0.05).dy,
      p(0.50, 0.04).dx, p(0.50, 0.04).dy,
    )
    ..cubicTo(
      p(0.44, 0.05).dx, p(0.44, 0.05).dy,
      p(0.38, 0.16).dx, p(0.38, 0.16).dy,
      p(0.36, 0.34).dx, p(0.36, 0.34).dy,
    )
    ..quadraticBezierTo(
      p(0.34, 0.28).dx, p(0.34, 0.28).dy,
      p(0.24, 0.22).dx, p(0.24, 0.22).dy,
    )
    ..cubicTo(
      p(0.22, 0.32).dx, p(0.22, 0.32).dy,
      p(0.14, 0.44).dx, p(0.14, 0.44).dy,
      p(0.04, 0.54).dx, p(0.04, 0.54).dy,
    )
    ..cubicTo(
      p(0.06, 0.76).dx, p(0.06, 0.76).dy,
      p(0.32, 0.92).dx, p(0.32, 0.92).dy,
      p(0.50, 0.94).dx, p(0.50, 0.94).dy,
    )
    ..close();
}

/// Longitudinal petal overlap ridges and central stamen accents for the lotus blossom.
Path lotusBlossomVeins(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  final path = Path()
    ..moveTo(p(0.50, 0.92).dx, p(0.50, 0.92).dy)
    ..quadraticBezierTo(
      p(0.51, 0.50).dx, p(0.51, 0.50).dy,
      p(0.50, 0.10).dx, p(0.50, 0.10).dy,
    )
    ..moveTo(p(0.48, 0.88).dx, p(0.48, 0.88).dy)
    ..quadraticBezierTo(
      p(0.36, 0.55).dx, p(0.36, 0.55).dy,
      p(0.26, 0.24).dx, p(0.26, 0.24).dy,
    )
    ..moveTo(p(0.52, 0.88).dx, p(0.52, 0.88).dy)
    ..quadraticBezierTo(
      p(0.64, 0.55).dx, p(0.64, 0.55).dy,
      p(0.74, 0.24).dx, p(0.74, 0.24).dy,
    )
    ..moveTo(p(0.44, 0.90).dx, p(0.44, 0.90).dy)
    ..quadraticBezierTo(
      p(0.24, 0.72).dx, p(0.24, 0.72).dy,
      p(0.08, 0.56).dx, p(0.08, 0.56).dy,
    )
    ..moveTo(p(0.56, 0.90).dx, p(0.56, 0.90).dy)
    ..quadraticBezierTo(
      p(0.76, 0.72).dx, p(0.76, 0.72).dy,
      p(0.92, 0.56).dx, p(0.92, 0.56).dy,
    );

  for (final fx in [0.44, 0.47, 0.50, 0.53, 0.56]) {
    path
      ..moveTo(p(0.50, 0.88).dx, p(0.50, 0.88).dy)
      ..lineTo(p(fx, 0.74).dx, p(fx, 0.74).dy);
  }

  return path;
}

/// A 5-petal pinwheel Frangipani / Plumeria blossom with spiraling, rounded petals.
Path plumeriaBlossomPath(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const petals = 5;

  final path = Path();
  for (var i = 0; i < petals; i++) {
    final aStart = -math.pi / 2 + i * 2 * math.pi / petals;

    Offset pt(double rFrac, double aOffset) {
      final a = aStart + aOffset;
      final r = baseR * rFrac;
      return Offset(cx + math.cos(a) * r, cy + math.sin(a) * r);
    }

    final pBase = pt(0.08, 0.0);
    final pInnerLeft = pt(0.35, 0.15);
    final pOuterLeft = pt(0.85, 0.35);
    final pTip = pt(0.96, 0.58);
    final pOuterRight = pt(0.70, 0.72);
    final pBaseRight = pt(0.20, 0.65);

    path.moveTo(pBase.dx, pBase.dy);
    path.cubicTo(
      pInnerLeft.dx, pInnerLeft.dy,
      pOuterLeft.dx, pOuterLeft.dy,
      pTip.dx, pTip.dy,
    );
    path.cubicTo(
      pOuterRight.dx, pOuterRight.dy,
      pBaseRight.dx, pBaseRight.dy,
      pBase.dx, pBase.dy,
    );
  }
  return path;
}

/// Central pinwheel whorl star and delicate radial petal creases.
Path plumeriaBlossomVeins(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const petals = 5;

  final path = Path();
  path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: baseR * 0.10));

  for (var i = 0; i < petals; i++) {
    final aStart = -math.pi / 2 + i * 2 * math.pi / petals;
    final stamenTip = Offset(
      cx + math.cos(aStart + 0.38) * baseR * 0.55,
      cy + math.sin(aStart + 0.38) * baseR * 0.55,
    );
    final stamenBase = Offset(
      cx + math.cos(aStart + 0.10) * baseR * 0.10,
      cy + math.sin(aStart + 0.10) * baseR * 0.10,
    );
    path
      ..moveTo(stamenBase.dx, stamenBase.dy)
      ..quadraticBezierTo(
        cx + math.cos(aStart + 0.25) * baseR * 0.35,
        cy + math.sin(aStart + 0.25) * baseR * 0.35,
        stamenTip.dx,
        stamenTip.dy,
      );
  }
  return path;
}

/// A 5-lobed wild rose blossom with wide heart-notched petals.
Path wildRoseBlossomPath(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const petals = 5;

  final path = Path();
  for (var i = 0; i < petals; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / petals;

    Offset pt(double rFrac, double aOffset) {
      final a = angle + aOffset;
      final r = baseR * rFrac;
      return Offset(cx + math.cos(a) * r, cy + math.sin(a) * r);
    }

    final pBaseLeft = pt(0.14, -0.32);
    final pMidLeft = pt(0.65, -0.48);
    final pLobeLeft = pt(0.95, -0.26);
    final pHeartNotch = pt(0.80, 0.0);
    final pLobeRight = pt(0.95, 0.26);
    final pMidRight = pt(0.65, 0.48);
    final pBaseRight = pt(0.14, 0.32);

    path.moveTo(pBaseLeft.dx, pBaseLeft.dy);
    path.cubicTo(
      pMidLeft.dx, pMidLeft.dy,
      pLobeLeft.dx, pLobeLeft.dy,
      pLobeLeft.dx, pLobeLeft.dy,
    );
    path.cubicTo(
      pt(0.92, -0.12).dx, pt(0.92, -0.12).dy,
      pHeartNotch.dx, pHeartNotch.dy,
      pHeartNotch.dx, pHeartNotch.dy,
    );
    path.cubicTo(
      pt(0.92, 0.12).dx, pt(0.92, 0.12).dy,
      pLobeRight.dx, pLobeRight.dy,
      pLobeRight.dx, pLobeRight.dy,
    );
    path.cubicTo(
      pMidRight.dx, pMidRight.dy,
      pBaseRight.dx, pBaseRight.dy,
      pBaseRight.dx, pBaseRight.dy,
    );
    path.quadraticBezierTo(
      cx, cy,
      pBaseLeft.dx, pBaseLeft.dy,
    );
  }
  return path;
}

/// A dense central ring of pistils and stamens with fine radial petal veins.
Path wildRoseBlossomVeins(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const petals = 5;

  final path = Path();
  // Central ring
  path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: baseR * 0.18));

  // Stamen ring around center
  const stamens = 15;
  for (var j = 0; j < stamens; j++) {
    final a = j * 2 * math.pi / stamens;
    final tip = Offset(
      cx + math.cos(a) * baseR * 0.32,
      cy + math.sin(a) * baseR * 0.32,
    );
    final base = Offset(
      cx + math.cos(a) * baseR * 0.18,
      cy + math.sin(a) * baseR * 0.18,
    );
    path
      ..moveTo(base.dx, base.dy)
      ..lineTo(tip.dx, tip.dy)
      ..addOval(Rect.fromCircle(center: tip, radius: baseR * 0.02));
  }

  // Petal vein lines
  for (var i = 0; i < petals; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / petals;
    for (final offset in [-0.20, 0.0, 0.20]) {
      final a = angle + offset;
      final from = Offset(cx + math.cos(a) * baseR * 0.34, cy + math.sin(a) * baseR * 0.34);
      final to = Offset(cx + math.cos(a) * baseR * 0.70, cy + math.sin(a) * baseR * 0.70);
      path
        ..moveTo(from.dx, from.dy)
        ..lineTo(to.dx, to.dy);
    }
  }
  return path;
}

/// A multi-petal radial starburst sunflower with 12 ray petals and a central seed disc.
Path sunflowerBlossomPath(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const rays = 12;

  final path = Path();
  // Central disc
  path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: baseR * 0.36));

  for (var i = 0; i < rays; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / rays;

    Offset pt(double rFrac, double aOffset) {
      final a = angle + aOffset;
      final r = baseR * rFrac;
      return Offset(cx + math.cos(a) * r, cy + math.sin(a) * r);
    }

    final pBaseLeft = pt(0.34, -0.16);
    final pMidLeft = pt(0.68, -0.12);
    final pTip = pt(0.96, 0.0);
    final pMidRight = pt(0.68, 0.12);
    final pBaseRight = pt(0.34, 0.16);

    path.moveTo(pBaseLeft.dx, pBaseLeft.dy);
    path.cubicTo(
      pMidLeft.dx, pMidLeft.dy,
      pTip.dx, pTip.dy,
      pTip.dx, pTip.dy,
    );
    path.cubicTo(
      pTip.dx, pTip.dy,
      pMidRight.dx, pMidRight.dy,
      pBaseRight.dx, pBaseRight.dy,
    );
  }
  return path;
}

/// A stippled seed disc and radial ray petal midribs for the sunflower blossom.
Path sunflowerBlossomVeins(Rect rect) {
  final cx = rect.left + rect.width / 2;
  final cy = rect.top + rect.height / 2;
  final baseR = math.min(rect.width, rect.height) / 2 * 0.90;
  const rays = 12;

  final path = Path();

  // Seed disc inner crosshatch rings
  for (final rFrac in [0.15, 0.26]) {
    path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: baseR * rFrac));
  }

  // Ray midribs
  for (var i = 0; i < rays; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / rays;
    final from = Offset(cx + math.cos(angle) * baseR * 0.36, cy + math.sin(angle) * baseR * 0.36);
    final to = Offset(cx + math.cos(angle) * baseR * 0.90, cy + math.sin(angle) * baseR * 0.90);
    path
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy);
  }
  return path;
}

/// An elegant fluted 3-pointed tulip cup contour.
Path tulipBlossomPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.96).dx, p(0.50, 0.96).dy)
    // Left outer flare up to left peak
    ..cubicTo(
      p(0.24, 0.90).dx, p(0.24, 0.90).dy,
      p(0.12, 0.52).dx, p(0.12, 0.52).dy,
      p(0.18, 0.16).dx, p(0.18, 0.16).dy,
    )
    // Cleft down to left-center cleft
    ..cubicTo(
      p(0.28, 0.28).dx, p(0.28, 0.28).dy,
      p(0.36, 0.32).dx, p(0.36, 0.32).dy,
      p(0.38, 0.34).dx, p(0.38, 0.34).dy,
    )
    // Up to towering center peak
    ..cubicTo(
      p(0.42, 0.16).dx, p(0.42, 0.16).dy,
      p(0.48, 0.05).dx, p(0.48, 0.05).dy,
      p(0.50, 0.04).dx, p(0.50, 0.04).dy,
    )
    // Down to right-center cleft
    ..cubicTo(
      p(0.52, 0.05).dx, p(0.52, 0.05).dy,
      p(0.58, 0.16).dx, p(0.58, 0.16).dy,
      p(0.62, 0.34).dx, p(0.62, 0.34).dy,
    )
    // Cleft to right peak
    ..cubicTo(
      p(0.64, 0.32).dx, p(0.64, 0.32).dy,
      p(0.72, 0.28).dx, p(0.72, 0.28).dy,
      p(0.82, 0.16).dx, p(0.82, 0.16).dy,
    )
    // Right outer flare down to stem base
    ..cubicTo(
      p(0.88, 0.52).dx, p(0.88, 0.52).dy,
      p(0.76, 0.90).dx, p(0.76, 0.90).dy,
      p(0.50, 0.96).dx, p(0.50, 0.96).dy,
    )
    ..close();
}

/// Inner overlapping petal curves and central stamen filaments for the tulip.
Path tulipBlossomVeins(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  final path = Path()
    // Left petal overlap curve
    ..moveTo(p(0.38, 0.34).dx, p(0.38, 0.34).dy)
    ..cubicTo(
      p(0.36, 0.60).dx, p(0.36, 0.60).dy,
      p(0.42, 0.82).dx, p(0.42, 0.82).dy,
      p(0.50, 0.94).dx, p(0.50, 0.94).dy,
    )
    // Right petal overlap curve
    ..moveTo(p(0.62, 0.34).dx, p(0.62, 0.34).dy)
    ..cubicTo(
      p(0.64, 0.60).dx, p(0.64, 0.60).dy,
      p(0.58, 0.82).dx, p(0.58, 0.82).dy,
      p(0.50, 0.94).dx, p(0.50, 0.94).dy,
    )
    // Center petal midrib
    ..moveTo(p(0.50, 0.94).dx, p(0.50, 0.94).dy)
    ..lineTo(p(0.50, 0.12).dx, p(0.50, 0.12).dy);

  // Central stamens rising out of cup
  for (final fx in [0.44, 0.50, 0.56]) {
    path
      ..moveTo(p(0.50, 0.85).dx, p(0.50, 0.85).dy)
      ..lineTo(p(fx, 0.38).dx, p(fx, 0.38).dy)
      ..addOval(Rect.fromCircle(center: p(fx, 0.38), radius: w * 0.02));
  }

  return path;
}

/// A variation of [petalPath] resembling a teardrop/raindrop: pointed at the tip,
/// with one flank swelling out slightly wider than the other for a subtle, natural asymmetry.
Path raindropPetalPath(Rect rect) {
  final w = rect.width;
  final h = rect.height;
  Offset p(double fx, double fy) =>
      Offset(rect.left + fx * w, rect.top + fy * h);

  return Path()
    ..moveTo(p(0.50, 0.04).dx, p(0.50, 0.04).dy)
    ..cubicTo(
      p(0.92, 0.24).dx, p(0.92, 0.24).dy,
      p(0.98, 0.62).dx, p(0.98, 0.62).dy,
      p(0.52, 0.96).dx, p(0.52, 0.96).dy,
    )
    ..cubicTo(
      p(0.18, 0.70).dx, p(0.18, 0.70).dy,
      p(0.12, 0.26).dx, p(0.12, 0.26).dy,
      p(0.50, 0.04).dx, p(0.50, 0.04).dy,
    )
    ..close();
}

/// Renders a multi-layered wet-in-wet watercolor wash over [path]:
/// 1. Off-center radial highlight fading into rich pigment & deep undertone pool.
/// 2. Multi-stop tide line gradient simulating dried pigment rings.
/// 3. Soft outer blur glow for paper fiber absorption.
/// 4. Delicate dark pigment stroke along the rim (watercolor edge effect).
void paintWatercolorPetal(Canvas canvas, Path path, Rect rect, Color color) {
  final center = Offset(rect.left + rect.width * 0.38, rect.top + rect.height * 0.38);
  final radius = math.max(rect.width, rect.height) * 0.70;

  // Layer 1: Radial wet-in-wet pigment pool
  final radialShader = ui.Gradient.radial(
    center,
    radius,
    [
      Color.lerp(color, Colors.white, 0.55)!.withValues(alpha: 0.95),
      color.withValues(alpha: 0.92),
      Color.lerp(color, const Color(0xFF5A1E2D), 0.40)!.withValues(alpha: 0.88),
    ],
    const [0.0, 0.55, 1.0],
  );

  canvas.drawPath(
    path,
    Paint()
      ..shader = radialShader
      ..isAntiAlias = true,
  );

  // Layer 2: Tide line / dried pigment ring effect (multi-stop sweep across petal)
  final tideShader = ui.Gradient.linear(
    Offset(rect.left + rect.width * 0.15, rect.top + rect.height * 0.10),
    Offset(rect.right, rect.bottom),
    [
      Colors.white.withValues(alpha: 0.0),
      color.withValues(alpha: 0.15),
      Color.lerp(color, Colors.white, 0.30)!.withValues(alpha: 0.25),
      Color.lerp(color, const Color(0xFF4A1824), 0.35)!.withValues(alpha: 0.30),
      Colors.white.withValues(alpha: 0.0),
    ],
    const [0.0, 0.35, 0.60, 0.82, 1.0],
  );

  canvas.drawPath(
    path,
    Paint()
      ..shader = tideShader
      ..isAntiAlias = true,
  );

  // Layer 3: Soft paper bleed blur
  canvas.drawPath(
    path,
    Paint()
      ..color = color.withValues(alpha: 0.40)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4.5),
  );

  // Layer 4: Pigment rim stroke (characteristic dark watercolor edge where water dries last)
  canvas.drawPath(
    path,
    Paint()
      ..color = Color.lerp(color, const Color(0xFF38121B), 0.50)!.withValues(alpha: 0.42)
      ..style = PaintingStyle.stroke
      ..strokeWidth = rect.shortestSide * 0.018
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true,
  );
}





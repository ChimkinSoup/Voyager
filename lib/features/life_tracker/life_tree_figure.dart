import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// Where the seated figure occupies the canvas. Shared by the painter and the
/// page's tap target so the thing you can click is exactly the thing you can
/// see — the figure is baked into the background image, so it has no widget of
/// its own to hit-test against.
Rect lifeTreeFigureRect(LifeTreeGeometry geometry, Size size) {
  final height = geometry.figureHeight * size.height;
  final width = height * _aspect;
  final anchor = Offset(
    geometry.figureAnchor.dx * size.width,
    geometry.figureAnchor.dy * size.height,
  );
  // The anchor is the point on the trunk the figure sits on, which is under
  // its hips — not the middle of its body.
  return Rect.fromLTWH(
    anchor.dx - width * _seat.dx,
    anchor.dy - height * _seat.dy,
    width,
    height,
  );
}

/// Body width as a fraction of height, hat brim to dangling foot.
const _aspect = 0.86;

/// The hips, in the figure's own unit space. Everything pivots about this
/// point when the figure reclines, so the seat stays on the trunk however far
/// back it leans.
const _seat = Offset(0.49, 0.61);

/// One limb of the figure: a quadratic run that tapers from [w0] to [w1]. All
/// coordinates are unit-space fractions of the figure's box; all widths are
/// fractions of its height.
typedef _Bone = (Offset, Offset, Offset, double, double);

/// A seated body, in the order the parts stack. Everything hangs off the hips
/// at [_seat]: torso up and tilted back, one knee drawn up onto the trunk, the
/// other leg left to dangle.
const _bones = <_Bone>[
  // Far leg, hanging. Kept a touch narrower than the near one and swung
  // further back, so the two read as two legs rather than one wedge.
  (Offset(0.462, 0.612), Offset(0.545, 0.712), Offset(0.578, 0.800), 0.108, 0.082),
  (Offset(0.578, 0.800), Offset(0.612, 0.885), Offset(0.606, 0.962), 0.082, 0.054),
  (Offset(0.606, 0.962), Offset(0.578, 0.995), Offset(0.518, 0.986), 0.054, 0.034),
  // Torso, shoulders set back from the hips so it reads as leaning against
  // the trunk rather than sitting bolt upright.
  (Offset(0.355, 0.310), Offset(0.398, 0.448), Offset(0.490, 0.590), 0.170, 0.150),
  // Near leg, knee drawn up onto the trunk.
  (Offset(0.490, 0.585), Offset(0.660, 0.540), Offset(0.760, 0.556), 0.118, 0.090),
  (Offset(0.760, 0.556), Offset(0.790, 0.680), Offset(0.735, 0.782), 0.090, 0.060),
  (Offset(0.735, 0.782), Offset(0.700, 0.818), Offset(0.632, 0.812), 0.060, 0.038),
  // Arm, forearm coming to rest on the raised knee.
  (Offset(0.400, 0.345), Offset(0.370, 0.470), Offset(0.520, 0.560), 0.070, 0.045),
];

/// The head, under the brim. Only its jaw shows, between the brim's underside
/// and the shoulders — which is all the reference gives you too.
const _headCenter = Offset(0.420, 0.230);
const _headRadiusX = 0.078;
const _headRadiusY = 0.076;

/// The straw hat's cone, as apex / control / point pairs walked clockwise. The
/// slopes bow outward and the brim sags in the middle: a cone drawn with
/// straight edges reads as a paper party hat.
const _hatApex = Offset(0.418, 0.020);
const _hatBrimLeft = Offset(0.135, 0.220);
const _hatBrimRight = Offset(0.712, 0.196);
const _hatLeftControl = Offset(0.252, 0.128);
const _hatRightControl = Offset(0.604, 0.106);
const _hatUnderControl = Offset(0.420, 0.322);

/// The seated figure resting against the trunk, in the same loaded ink the
/// wood is painted with. Deliberately a silhouette: at this size the reference
/// resolves to little more than a hat, a slumped back and two legs, and
/// anything more detailed reads as a sticker rather than a brush mark.
void paintTreeFigure(
  Canvas canvas,
  Rect rect,
  Color ink,
  Color paper,
  double lean,
) {
  Offset at(Offset unit) => Offset(
        rect.left + unit.dx * rect.width,
        rect.top + unit.dy * rect.height,
      );
  double scale(double unit) => unit * rect.height;

  final pivot = at(_seat);
  canvas.save();
  canvas.translate(pivot.dx, pivot.dy);
  canvas.rotate(lean);
  canvas.translate(-pivot.dx, -pivot.dy);

  // Unioned rather than merely accumulated. Path.addPath keeps each run as its
  // own subpath, and a run whose winding happens to oppose its neighbour's
  // then punches a hole through it under the default non-zero fill — which is
  // exactly what the round joint caps did before.
  var body = Path();
  void merge(Path part) {
    body = Path.combine(PathOperation.union, body, part);
  }

  for (final bone in _bones) {
    final a = at(bone.$1);
    final c = at(bone.$3);
    merge(_taperedRun(a, at(bone.$2), c, scale(bone.$4), scale(bone.$5)));
  }
  merge(
    Path()
      ..addOval(
        Rect.fromCenter(
          center: at(_headCenter),
          width: scale(_headRadiusX * 2),
          height: scale(_headRadiusY * 2),
        ),
      ),
  );

  // A breath of bare paper around the silhouette. The figure is painted in the
  // same loaded ink as the trunk it rests on, so without this the two merge
  // into one dark mass and only the hat survives.
  canvas.drawPath(
    body,
    Paint()
      ..color = paper.withValues(alpha: 0.60)
      ..style = PaintingStyle.stroke
      ..strokeWidth = scale(0.034)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, scale(0.012)),
  );
  // Ink bleeding into damp paper, so the figure sits in the painting rather
  // than on top of it.
  canvas.drawPath(
    body,
    Paint()
      ..color = ink.withValues(alpha: 0.18)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, scale(0.012)),
  );
  canvas.drawPath(body, Paint()..color = ink.withValues(alpha: 0.95));

  // Broken highlights scrubbed back out of the body, the same dry-brush trick
  // the trunk uses. Run down the figure rather than across it, so they read as
  // folds in cloth instead of stripes painted over a silhouette.
  canvas.save();
  canvas.clipPath(body);
  final rand = math.Random(4211);
  final streak = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  for (var i = 0; i < 16; i++) {
    final a = at(
      Offset(0.34 + rand.nextDouble() * 0.42, 0.26 + rand.nextDouble() * 0.68),
    );
    final b = a +
        Offset(
          (rand.nextDouble() - 0.5) * scale(0.04),
          scale(0.06 + rand.nextDouble() * 0.12),
        );
    streak
      ..color = paper.withValues(alpha: 0.05 + rand.nextDouble() * 0.09)
      ..strokeWidth = scale(0.003 + rand.nextDouble() * 0.005);
    canvas.drawLine(a, b, streak);
  }

  // Mottled sumi-e clothing pattern on figure body, matching reference image.
  final dotPaint = Paint()..style = PaintingStyle.fill;
  for (var i = 0; i < 35; i++) {
    dotPaint.color = paper.withValues(alpha: 0.08 + rand.nextDouble() * 0.16);
    final p = at(
      Offset(0.35 + rand.nextDouble() * 0.40, 0.30 + rand.nextDouble() * 0.65),
    );
    canvas.drawCircle(p, scale(0.005 + rand.nextDouble() * 0.014), dotPaint);
  }
  canvas.restore();

  // The straw hat, lighter than the body and painted last so its brim cuts
  // across the shoulders.
  final hat = Path()
    ..moveTo(at(_hatApex).dx, at(_hatApex).dy)
    ..quadraticBezierTo(
      at(_hatLeftControl).dx,
      at(_hatLeftControl).dy,
      at(_hatBrimLeft).dx,
      at(_hatBrimLeft).dy,
    )
    ..quadraticBezierTo(
      at(_hatUnderControl).dx,
      at(_hatUnderControl).dy,
      at(_hatBrimRight).dx,
      at(_hatBrimRight).dy,
    )
    ..quadraticBezierTo(
      at(_hatRightControl).dx,
      at(_hatRightControl).dy,
      at(_hatApex).dx,
      at(_hatApex).dy,
    )
    ..close();

  canvas.drawPath(
    hat,
    Paint()
      ..color = paper.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = scale(0.030)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, scale(0.012)),
  );
  // Lit from above and shaded under the brim, so the cone has some turn to it
  // instead of reading as a flat grey triangle.
  final hatBounds = hat.getBounds();
  canvas.drawPath(
    hat,
    Paint()
      ..shader = ui.Gradient.linear(
        hatBounds.topCenter,
        hatBounds.bottomCenter,
        [
          Color.lerp(ink, paper, 0.58)!,
          Color.lerp(ink, paper, 0.44)!,
          Color.lerp(ink, paper, 0.22)!,
        ],
        const [0.0, 0.62, 1.0],
      ),
  );

  // Straw laid radially from the crown, and the ridge down the near side.
  canvas.save();
  canvas.clipPath(hat);
  final straw = Paint()..strokeWidth = scale(0.005);
  for (var i = 0; i <= 4; i++) {
    straw.color = ink.withValues(alpha: i == 2 ? 0.42 : 0.20);
    canvas.drawLine(
      at(const Offset(0.418, 0.030)),
      at(Offset.lerp(_hatBrimLeft, _hatBrimRight, i / 4)! + const Offset(0, 0.02)),
      straw,
    );
  }
  canvas.restore();

  canvas.drawPath(
    hat,
    Paint()
      ..color = ink.withValues(alpha: 0.58)
      ..style = PaintingStyle.stroke
      ..strokeWidth = scale(0.006),
  );

  canvas.restore();
}

/// A quadratic run swept out to a filled ribbon that narrows from [w0] to
/// [w1], sampled along the curve and offset along the normal at each step.
Path _taperedRun(Offset a, Offset b, Offset c, double w0, double w1) {
  const steps = 14;
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
    final half = (w0 + (w1 - w0) * t) / 2;
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

import 'dart:math';
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/core/utils/moon.dart';

/// How the header's moon is drawn.
enum GaiaMoonModel {
  /// The seas as soft shading, a crisp terminator.
  seas('Seas'),

  /// Lit as the real surface scatters light: an evenly bright full moon,
  /// the light falling away to a soft terminator; the seas as in [seas].
  sphere('Lit sphere'),

  /// [sphere], with small craters whose rims catch the light near the
  /// terminator.
  cratered('Cratered'),

  /// [sphere] without the seas.
  smooth('Smooth'),

  /// Flat, in the theme's ink, as the header's other icons are.
  ink('Ink');

  const GaiaMoonModel(this.label);
  final String label;
}

/// Where the moon's phase shows.
enum GaiaMoonPlace {
  /// Before the new chat's greeting.
  greeting('Greeting'),

  /// Still, in a top corner of the sky, coming and going with it.
  sky('Sky'),

  /// Beside the sidebar's "Gaia" title.
  sidebar('Sidebar');

  const GaiaMoonPlace(this.label);
  final String label;
}

/// What a moon is drawn against: the header's brightness, the theme's inks,
/// and the screen's pixels.
typedef GaiaMoonLook = ({bool dark, Color shade, Color ink, double pixelRatio});

GaiaMoonLook gaiaMoonLook(BuildContext context) {
  final theme = Theme.of(context);
  return (
    dark: theme.brightness == Brightness.dark,
    shade: theme.colorScheme.onSurface,
    ink: theme.colorScheme.onSurfaceVariant,
    pixelRatio: MediaQuery.devicePixelRatioOf(context),
  );
}

CustomPainter _painter(double phase, GaiaMoonModel model, GaiaMoonLook look) =>
    switch (model) {
      GaiaMoonModel.seas => _MoonPainter(
        phase: phase,
        dark: look.dark,
        shade: look.shade,
      ),
      GaiaMoonModel.sphere ||
      GaiaMoonModel.cratered ||
      GaiaMoonModel.smooth => _SphereMoonPainter(
        phase: phase,
        dark: look.dark,
        shade: look.shade,
        seas: model != GaiaMoonModel.smooth,
        craters: model == GaiaMoonModel.cratered,
        pixelRatio: look.pixelRatio,
      ),
      GaiaMoonModel.ink => _InkMoonPainter(phase: phase, ink: look.ink),
    };

/// A moon of [size] square recorded once, to draw again each frame without
/// working it out a pixel at a time each time.
ui.Picture gaiaMoonPicture(
  double phase,
  GaiaMoonModel model,
  GaiaMoonLook look,
  double size,
) {
  final recorder = ui.PictureRecorder();
  _painter(phase, model, look).paint(Canvas(recorder), Size.square(size));
  return recorder.endRecording();
}

/// The moon's phase, as it looks: lit on the right while
/// waxing and the left while waning, by [model]. Its tooltip names the
/// phase.
class GaiaMoonIcon extends StatelessWidget {
  const GaiaMoonIcon({
    super.key,
    required this.phase,
    this.model = GaiaMoonModel.cratered,
    this.size = 18,
  });

  /// 0 new, 0.5 full, back to 1.
  final double phase;
  final GaiaMoonModel model;
  final double size;

  static const _names = [
    'New moon',
    'Waxing crescent',
    'First quarter',
    'Waxing gibbous',
    'Full moon',
    'Waning gibbous',
    'Last quarter',
    'Waning crescent',
  ];

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          '${_names[(phase * 8).round() % 8]}, '
          '${(moonLit(phase) * 100).round()}% lit',
      child: CustomPaint(
        size: Size.square(size),
        painter: _painter(phase, model, gaiaMoonLook(context)),
      ),
    );
  }
}

/// The near side's seas and brightest craters, in a moon of radius 1 with
/// north up: each its middle, and its half-width and half-height.
const _maria = <(Offset, double, double)>[
  (Offset(-0.55, 0.02), 0.28, 0.48), // Oceanus Procellarum
  (Offset(-0.28, -0.42), 0.26, 0.24), // Mare Imbrium
  (Offset(-0.02, -0.72), 0.42, 0.08), // Mare Frigoris
  (Offset(0.18, -0.32), 0.15, 0.15), // Mare Serenitatis
  (Offset(0.36, -0.05), 0.2, 0.16), // Mare Tranquillitatis
  (Offset(0.68, -0.25), 0.11, 0.1), // Mare Crisium
  (Offset(0.6, 0.18), 0.11, 0.17), // Mare Fecunditatis
  (Offset(0.38, 0.32), 0.09, 0.09), // Mare Nectaris
  (Offset(-0.2, -0.04), 0.13, 0.1), // Mare Insularum and Vaporum
  (Offset(-0.15, 0.38), 0.17, 0.12), // Mare Nubium
  (Offset(-0.48, 0.42), 0.09, 0.09), // Mare Humorum
];

/// Tycho and Copernicus, bright against the highlands round them.
const _craters = <(Offset, double)>[
  (Offset(-0.1, 0.72), 0.06),
  (Offset(-0.3, -0.12), 0.045),
];

class _MoonPainter extends CustomPainter {
  _MoonPainter({required this.phase, required this.dark, required this.shade});

  final double phase;

  /// On a dark header the moon is pale; on a light one, a deeper grey, to
  /// show against it.
  final bool dark;

  /// The theme's ink, for the earthshine.
  final Color shade;

  /// The whole face, seas and all, about the origin.
  void _face(Canvas canvas, double r) {
    final highland = dark ? const Color(0xFFE8E4DA) : const Color(0xFFB8B2A6);
    final sea = dark ? const Color(0xFF9C998F) : const Color(0xFF8A857B);
    canvas.drawCircle(Offset.zero, r, Paint()..color = highland);
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: r)),
    );
    // Soft, so they read as shading rather than shapes.
    final blur = MaskFilter.blur(BlurStyle.normal, r * 0.09);
    final paint = Paint()
      ..color = sea.withValues(alpha: 0.55)
      ..maskFilter = blur;
    for (final (at, w, h) in _maria) {
      canvas.drawOval(
        Rect.fromCenter(center: at * r, width: 2 * w * r, height: 2 * h * r),
        paint,
      );
    }
    paint.color = Colors.white.withValues(alpha: dark ? 0.7 : 0.45);
    for (final (at, cr) in _craters) {
      canvas.drawCircle(at * r, cr * r, paint);
    }
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    canvas.translate(size.width / 2, size.height / 2);
    // The unlit part in a faint earthshine, so the whole disc shows; on a
    // light header, where a pale fill would read as the lit part, a faint
    // outline instead.
    canvas.drawCircle(
      Offset.zero,
      dark ? r : r - 0.5,
      dark
          ? (Paint()..color = shade.withValues(alpha: 0.1))
          : (Paint()
              ..color = shade.withValues(alpha: 0.25)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1),
    );
    // The lit part: the face, kept where the sun's on it. The seas stay
    // put; only the light moves across them.
    canvas.clipPath(_litPath(r, phase));
    _face(canvas, r);
  }

  @override
  bool shouldRepaint(_MoonPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.dark != dark ||
      oldDelegate.shade != shade;
}

/// [moonLitPath], mirrored for a waning moon.
Path _litPath(double r, double phase) {
  final lit = moonLitPath(r, phase);
  if (phase <= 0.5) return lit;
  return lit.transform(
    Float64List.fromList([
      -1, 0, 0, 0, //
      0, 1, 0, 0, //
      0, 0, 1, 0, //
      0, 0, 0, 1, //
    ]),
  );
}

/// The surface's brightness at ([x], [y]) in a moon of radius 1, 0 to 1:
/// darker in the seas, each with a soft shore and overlapping ones no
/// darker, as the seas' moon has them; bright at Tycho and Copernicus.
double _albedo(double x, double y) {
  var clear = 1.0;
  for (final (at, w, h) in _maria) {
    final dx = (x - at.dx) / w, dy = (y - at.dy) / h;
    final e = sqrt(dx * dx + dy * dy);
    // Soft over about the seas' moon's blur, whatever the sea's size.
    final soft = 0.12 / min(w, h);
    final t = ((e - 1 + soft) / (2 * soft)).clamp(0.0, 1.0);
    clear *= 1 - 0.55 * (1 - t * t * (3 - 2 * t));
  }
  var a = clear;
  for (final (at, cr) in _craters) {
    final dx = x - at.dx, dy = y - at.dy;
    a += 0.5 * exp(-(dx * dx + dy * dy) / (cr * cr));
  }
  return a.clamp(0.0, 1.0);
}

/// Small craters scattered over the face, the same every time: each its
/// middle and radius, in a moon of radius 1.
final _craterField = () {
  final random = Random(7);
  final field = <(double, double, double)>[];
  while (field.length < 45) {
    final x = random.nextDouble() * 2 - 1, y = random.nextDouble() * 2 - 1;
    if (x * x + y * y > 0.85) continue;
    field.add((x, y, 0.03 + 0.07 * pow(random.nextDouble(), 2)));
  }
  return field;
}();

/// The moon drawn a device pixel at a time, lit as the real surface scatters
/// light (Lommel-Seeliger): no darker at the limb, so a full moon is evenly
/// bright, and falling away smoothly to the terminator.
class _SphereMoonPainter extends CustomPainter {
  _SphereMoonPainter({
    required this.phase,
    required this.dark,
    required this.shade,
    required this.seas,
    required this.craters,
    required this.pixelRatio,
  });

  final double phase;
  final bool dark;
  final Color shade;
  final bool seas;
  final bool craters;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    canvas.translate(size.width / 2, size.height / 2);
    // As the seas' moon: an outline for the unlit part on a light header.
    if (!dark) {
      canvas.drawCircle(
        Offset.zero,
        r - 0.5,
        Paint()
          ..color = shade.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final highland = dark ? const Color(0xFFE8E4DA) : const Color(0xFFB8B2A6);
    final sea = dark ? const Color(0xFF9C998F) : const Color(0xFF8A857B);
    // Faint earthshine over the unlit part, on a dark header.
    final earth = dark ? 0.1 : 0.0;
    // The sun's direction, the viewer along +z: behind the moon when new,
    // to the right at first quarter.
    final theta = 2 * pi * phase;
    final sx = sin(theta), sz = -cos(theta);
    final n = max(1, (2 * r * pixelRatio).ceil());
    final step = 2 * r / n;
    final paint = Paint()..isAntiAlias = false;
    for (var j = 0; j < n; j++) {
      final y = (-r + (j + 0.5) * step) / r;
      for (var i = 0; i < n; i++) {
        final x = (-r + (i + 0.5) * step) / r;
        final d2 = x * x + y * y;
        // How much of the pixel the disc covers, for a smooth edge.
        final cover = ((1 - sqrt(d2)) * r / step + 0.5).clamp(0.0, 1.0);
        if (cover <= 0) continue;
        var nx = x, ny = y, nz = sqrt(max(0.0, 1 - d2));
        if (craters) {
          // Each a bowl inside a raised rim, tilting the surface.
          for (final (cx, cy, cr) in _craterField) {
            final dx = x - cx, dy = y - cy;
            final q = sqrt(dx * dx + dy * dy) / cr;
            if (q >= 1.4 || q == 0) continue;
            final slope = q < 1 ? 0.9 * q : -0.9 * (1.4 - q) / 0.4;
            nx -= 0.35 * slope * dx / (q * cr);
            ny -= 0.35 * slope * dy / (q * cr);
          }
          final length = sqrt(nx * nx + ny * ny + nz * nz);
          nx /= length;
          ny /= length;
          nz /= length;
        }
        final mu0 = nx * sx + nz * sz;
        final mu = max(nz, 0.05);
        final light = mu0 <= 0 ? 0.0 : min(1.0, 2 * mu0 / (mu0 + mu));
        final colour = seas
            ? Color.lerp(sea, highland, _albedo(x, y))!
            : highland;
        final alpha = (earth + (1 - earth) * light) * cover;
        if (alpha <= 0) continue;
        canvas.drawRect(
          Rect.fromLTWH(-r + i * step, -r + j * step, step, step),
          paint..color = colour.withValues(alpha: alpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SphereMoonPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.dark != dark ||
      oldDelegate.shade != shade ||
      oldDelegate.seas != seas ||
      oldDelegate.craters != craters ||
      oldDelegate.pixelRatio != pixelRatio;
}

/// The moon as a flat icon: an outline, the lit part filled in [ink].
class _InkMoonPainter extends CustomPainter {
  _InkMoonPainter({required this.phase, required this.ink});

  final double phase;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..drawCircle(
        Offset.zero,
        r - 0.6,
        Paint()
          ..color = ink.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      )
      ..drawPath(_litPath(r, phase), Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_InkMoonPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.ink != ink;
}

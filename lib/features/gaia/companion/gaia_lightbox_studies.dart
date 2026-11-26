import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/features/gaia/companion/gaia_lightbox.dart';

/// A study picture: drawn rather than decoded, so it's crisp at any zoom
/// and costs nothing until shown.
typedef _Sample = ({String name, Size size, CustomPainter painter});

final _samples = <_Sample>[
  (name: 'dusk.png', size: const Size(1600, 1000), painter: _DuskPainter()),
  (name: 'diagram.png', size: const Size(1200, 1200), painter: _GridPainter()),
  (name: 'portrait.png', size: const Size(900, 1400), painter: _TallPainter()),
  (
    name: 'screenshot.png',
    size: const Size(1920, 1080),
    painter: _ScreenPainter(),
  ),
];

/// The debug menu's study of Gaia's lightbox, the one the chat opens, on
/// sample pictures.
class GaiaLightboxStudy extends StatelessWidget {
  const GaiaLightboxStudy({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Click a picture. Esc or a click beside it closes; Left and Right '
          'move; + and - zoom, 0 fits; a double click zooms to a point; '
          'Ctrl and the wheel zoom too, and a drag pans.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, picture) in _pictures.indexed)
              GaiaLightboxThumb(
                picture: picture,
                width: 112,
                height: 76,
                onTap: () =>
                    showGaiaPictures(context, pictures: _pictures, initial: i),
              ),
          ],
        ),
      ],
    );
  }
}

/// A sample as a lightbox picture. Its bytes are the painting, drawn to a
/// PNG, so Copy and Save work in the study too.
class _SamplePicture implements GaiaLightboxPicture {
  const _SamplePicture(this.sample);

  final _Sample sample;

  @override
  String get name => sample.name;

  @override
  Size get size => sample.size;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: sample.painter);

  @override
  Future<({Uint8List bytes, MediaImageFormat? format})?> read() async {
    final recorder = ui.PictureRecorder();
    sample.painter.paint(Canvas(recorder), sample.size);
    final image = await recorder.endRecording().toImage(
      sample.size.width.round(),
      sample.size.height.round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return (bytes: data!.buffer.asUint8List(), format: MediaImageFormat.png);
  }

  @override
  String get saveName => sample.name.replaceAll('.png', '');
}

final _pictures = [for (final sample in _samples) _SamplePicture(sample)];

/// A sunset over hills.
class _DuskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B2A4A), Color(0xFF7A4B7E), Color(0xFFF2A65A)],
          stops: [0, 0.55, 0.85],
        ).createShader(rect),
    );
    final sun = Offset(size.width * 0.68, size.height * 0.62);
    canvas.drawCircle(
      sun,
      size.width * 0.14,
      Paint()
        ..color = const Color(0x55FFD9A0)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.04),
    );
    canvas.drawCircle(
      sun,
      size.width * 0.07,
      Paint()..color = const Color(0xFFFFE3B0),
    );
    for (final (height, color, phase) in [
      (0.62, const Color(0xFF3B2B4F), 0.0),
      (0.72, const Color(0xFF261D36), 1.7),
      (0.84, const Color(0xFF140F1E), 3.1),
    ]) {
      final path = Path()..moveTo(0, size.height);
      for (var x = 0.0; x <= 1.0001; x += 0.02) {
        final y =
            height +
            0.04 * math.sin(x * 7 + phase) +
            0.025 * math.sin(x * 17 + phase * 2);
        path.lineTo(x * size.width, y * size.height);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_DuskPainter old) => false;
}

/// A diagram on a grid, with small print to zoom in on.
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF101418),
    );
    final step = size.width / 24;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = size.width / 1200;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    const colors = [
      Color(0xFF5B8DEF),
      Color(0xFF3FBF9F),
      Color(0xFFE0A84F),
      Color(0xFFD9667A),
    ];
    final boxes = [
      Rect.fromLTWH(3, 3, 7, 4),
      Rect.fromLTWH(14, 3, 7, 4),
      Rect.fromLTWH(3, 12, 7, 4),
      Rect.fromLTWH(14, 12, 7, 4),
    ];
    final link = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = size.width / 400
      ..style = PaintingStyle.stroke;
    canvas
      ..drawLine(Offset(10 * step, 5 * step), Offset(14 * step, 5 * step), link)
      ..drawLine(
        Offset(6.5 * step, 7 * step),
        Offset(6.5 * step, 12 * step),
        link,
      )
      ..drawLine(
        Offset(17.5 * step, 7 * step),
        Offset(17.5 * step, 12 * step),
        link,
      );
    for (final (i, box) in boxes.indexed) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          box.left * step,
          box.top * step,
          box.width * step,
          box.height * step,
        ),
        Radius.circular(step * 0.4),
      );
      canvas
        ..drawRRect(r, Paint()..color = colors[i].withValues(alpha: 0.18))
        ..drawRRect(
          r,
          Paint()
            ..color = colors[i]
            ..style = PaintingStyle.stroke
            ..strokeWidth = size.width / 600,
        );
      _text(
        canvas,
        ['Inbox', 'Plan', 'Do', 'Done'][i],
        r.outerRect.center,
        size.width * 0.03,
        Colors.white,
      );
    }
    _text(
      canvas,
      'Small print: zoom in to read this line.',
      Offset(size.width / 2, 20 * step),
      size.width * 0.011,
      Colors.white.withValues(alpha: 0.6),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

/// A tall picture of soft circles.
class _TallPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F5D63), Color(0xFF2D2A6E), Color(0xFF120E2B)],
        ).createShader(rect),
    );
    final random = math.Random(7);
    for (var i = 0; i < 26; i++) {
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        size.width * (0.02 + random.nextDouble() * 0.12),
        Paint()
          ..color = Colors.white.withValues(
            alpha: 0.04 + random.nextDouble() * 0.12,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_TallPainter old) => false;
}

/// A mock window, as a screenshot would be.
class _ScreenPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas
      ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1E1F22))
      ..drawRect(
        Rect.fromLTWH(0, 0, w, h * 0.045),
        Paint()..color = const Color(0xFF2B2D31),
      )
      ..drawRect(
        Rect.fromLTWH(0, h * 0.045, w * 0.18, h),
        Paint()..color = const Color(0xFF232428),
      );
    for (final (i, color) in [
      const Color(0xFFED6A5E),
      const Color(0xFFF5BF4F),
      const Color(0xFF61C554),
    ].indexed) {
      canvas.drawCircle(
        Offset(w * (0.012 + i * 0.012), h * 0.0225),
        h * 0.008,
        Paint()..color = color,
      );
    }
    final bar = Paint()..color = Colors.white.withValues(alpha: 0.12);
    for (var i = 0; i < 12; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.015, h * (0.08 + i * 0.055), w * 0.13, h * 0.025),
          Radius.circular(h * 0.006),
        ),
        i == 2 ? (Paint()..color = const Color(0x665B8DEF)) : bar,
      );
    }
    final random = math.Random(3);
    for (var i = 0; i < 16; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            w * 0.22,
            h * (0.1 + i * 0.045),
            w * (0.3 + random.nextDouble() * 0.4),
            h * 0.016,
          ),
          Radius.circular(h * 0.004),
        ),
        Paint()..color = Colors.white.withValues(alpha: i % 5 == 0 ? 0.3 : 0.1),
      );
    }
    _text(
      canvas,
      'Gaia lightbox study',
      Offset(w / 2, h * 0.0225),
      h * 0.018,
      Colors.white.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(_ScreenPainter old) => false;
}

/// [text] centred on [at].
void _text(Canvas canvas, String text, Offset at, double size, Color color) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  painter.dispose();
}

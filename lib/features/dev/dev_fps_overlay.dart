import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/dev/fps_monitor.dart';
import 'package:voyager/features/dev/dev_page.dart';

const double _graphWidth = 132;
const double _graphHeight = 34;

/// Top-right rendered-FPS readout with a five-minute history graph.
///
/// Gated on the Dev page toggle; while off, [FpsMonitor] is fully detached and
/// this builds to nothing.
class FpsOverlay extends ConsumerWidget {
  const FpsOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(devShowFpsCounterProvider)) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Positioned(
      top: 12,
      right: 12,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.35),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: ListenableBuilder(
                listenable: FpsMonitor.instance,
                builder: (context, _) => _FpsReadout(
                  current: FpsMonitor.instance.current,
                  history: FpsMonitor.instance.history,
                  accent: theme.colorScheme.primary,
                  onSurface: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FpsReadout extends StatelessWidget {
  const _FpsReadout({
    required this.current,
    required this.history,
    required this.accent,
    required this.onSurface,
  });

  final double? current;
  final List<double?> history;
  final Color accent;
  final Color onSurface;

  @override
  Widget build(BuildContext context) {
    final value = current;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value == null ? '--' : value.round().toString(),
              style: TextStyle(
                color: onSurface,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w600,
                // Stop the readout jittering as digits change width.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'FPS',
              style: TextStyle(
                color: onSurface.withValues(alpha: 0.55),
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        CustomPaint(
          size: const Size(_graphWidth, _graphHeight),
          painter: _FpsGraphPainter(
            history: history,
            accent: accent,
            onSurface: onSurface,
          ),
        ),
      ],
    );
  }
}

class _FpsGraphPainter extends CustomPainter {
  _FpsGraphPainter({
    required this.history,
    required this.accent,
    required this.onSurface,
  });

  final List<double?> history;
  final Color accent;
  final Color onSurface;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = onSurface.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      baseline,
    );

    var peak = 0.0;
    for (final sample in history) {
      if (sample != null && sample > peak) peak = sample;
    }
    if (peak <= 0) {
      _paintPeakLabel(canvas, size, null);
      return;
    }

    // Newest sample pins to the right edge and the window keeps its full
    // five-minute width, so a fresh graph fills in from the right instead of
    // stretching a handful of samples across the whole box.
    final step = size.width / (FpsMonitor.historyLength - 1);
    final firstIndex = FpsMonitor.historyLength - history.length;

    double xFor(int index) => (firstIndex + index) * step;
    double yFor(double fps) => size.height - (fps / peak) * (size.height - 1);

    final line = Path();
    final fill = Path();
    var penDown = false;
    var segmentStartX = 0.0;

    void closeSegment(double endX) {
      if (!penDown) return;
      fill
        ..lineTo(endX, size.height)
        ..lineTo(segmentStartX, size.height)
        ..close();
      penDown = false;
    }

    for (var i = 0; i < history.length; i++) {
      final sample = history[i];
      final x = xFor(i);
      if (sample == null) {
        closeSegment(xFor(i - 1));
        continue;
      }
      final point = Offset(x, yFor(sample));
      if (penDown) {
        line.lineTo(point.dx, point.dy);
        fill.lineTo(point.dx, point.dy);
      } else {
        line.moveTo(point.dx, point.dy);
        fill.moveTo(point.dx, point.dy);
        segmentStartX = x;
        penDown = true;
      }
    }
    closeSegment(xFor(history.length - 1));

    canvas.drawPath(
      fill,
      Paint()..color = accent.withValues(alpha: 0.16),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );

    _paintPeakLabel(canvas, size, peak);
  }

  void _paintPeakLabel(Canvas canvas, Size size, double? peak) {
    final painter = TextPainter(
      text: TextSpan(
        text: peak == null ? '--' : peak.round().toString(),
        style: TextStyle(
          color: onSurface.withValues(alpha: 0.5),
          fontSize: 9,
          height: 1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(size.width - painter.width, 0));
  }

  @override
  bool shouldRepaint(covariant _FpsGraphPainter oldDelegate) =>
      !identical(oldDelegate.history, history) ||
      oldDelegate.accent != accent ||
      oldDelegate.onSurface != onSurface;
}

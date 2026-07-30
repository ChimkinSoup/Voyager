import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/fps_monitor_controller.dart';

const double _graphWidth = 132;
const double _graphHeight = 34;

class DevFpsCounterSection extends ConsumerWidget {
  const DevFpsCounterSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devSettings = ref.watch(devSettingsProvider);

    return SwitchListTile(
      title: const Text('Show FPS counter'),
      subtitle: const Text(
        'Overlay a live rendered-frame-rate reading and a five-minute graph, '
        'top-right. Sampled passively from frame reports — it never drives its '
        'own ticker, so it costs nothing when the screen is idle.',
      ),
      value: devSettings.showFpsCounter,
      onChanged: (value) {
        unawaited(ref.read(devSettingsProvider).setShowFpsCounter(value));
      },
    );
  }
}

/// Top-right HUD showing live rendered FPS and the last five minutes of
/// samples. Mount once, app-wide, alongside [CacheStatusOverlay] — it no-ops
/// (and its monitor stays detached) until the dev toggle is on.
class FpsCounterOverlay extends ConsumerWidget {
  const FpsCounterOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(
      devSettingsProvider.select((s) => s.showFpsCounter),
    );
    if (!visible) return const SizedBox.shrink();

    return const Positioned(
      top: 12,
      right: 12,
      child: IgnorePointer(child: _FpsCard()),
    );
  }
}

class _FpsCard extends ConsumerWidget {
  const _FpsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monitor = ref.watch(fpsMonitorProvider);
    final theme = Theme.of(context);

    return RepaintBoundary(
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
          child: _FpsReadout(
            current: monitor.currentFps,
            history: monitor.history,
            accent: theme.colorScheme.primary,
            onSurface: theme.colorScheme.onSurface,
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

/// Sparkline of the last five minutes of rendered-FPS samples (one per second,
/// oldest left). Null samples — seconds with no rendered frame — are drawn as
/// gaps rather than drops to zero.
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
    final step = size.width / (FpsMonitorController.historyLength - 1);
    final firstIndex = FpsMonitorController.historyLength - history.length;

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

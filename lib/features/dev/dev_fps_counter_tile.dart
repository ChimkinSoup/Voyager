import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';

class DevFpsCounterSection extends ConsumerWidget {
  const DevFpsCounterSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devSettings = ref.watch(devSettingsProvider);

    return SwitchListTile(
      title: const Text('Show FPS counter'),
      subtitle: const Text(
        'Overlay a live frame-rate reading and a last-minute graph, top-right. '
        'Runs its own ticker at native refresh rate while shown.',
      ),
      value: devSettings.showFpsCounter,
      onChanged: (value) {
        unawaited(ref.read(devSettingsProvider).setShowFpsCounter(value));
      },
    );
  }
}

/// Top-right HUD showing live FPS and the last minute of samples. Mount once,
/// app-wide, alongside [CacheStatusOverlay] — it no-ops (and its driving
/// ticker stays stopped) until the dev toggle is on.
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
    final fps = monitor.currentFps;
    final color = _fpsColor(fps);

    return Material(
      elevation: 6,
      color: theme.colorScheme.surface.withValues(alpha: 0.96),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              fps <= 0 ? '-- fps' : '${fps.round()} fps',
              style: theme.textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 130,
              height: 36,
              child: CustomPaint(
                painter: _FpsGraphPainter(
                  history: monitor.history,
                  color: color,
                  dividerColor: theme.dividerColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Color _fpsColor(double fps) {
  if (fps <= 0) return Colors.grey;
  if (fps >= 50) return Colors.greenAccent.shade400;
  if (fps >= 30) return Colors.orangeAccent;
  return Colors.redAccent;
}

/// Sparkline of the last minute of FPS samples (one per second, oldest left).
class _FpsGraphPainter extends CustomPainter {
  _FpsGraphPainter({
    required this.history,
    required this.color,
    required this.dividerColor,
  });

  final List<double> history;
  final Color color;
  final Color dividerColor;

  static const _minScale = 30.0;
  static const _maxScale = 144.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    var maxSample = _minScale;
    for (final sample in history) {
      if (sample > maxSample) maxSample = sample;
    }
    final scale = math.min(maxSample, _maxScale);

    // Reference line at 60fps, when it's within the visible scale.
    if (scale > 60) {
      final y = size.height - (60 / scale) * size.height;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = dividerColor
          ..strokeWidth = 1,
      );
    }

    final path = Path();
    final stepX = history.length > 1
        ? size.width / (history.length - 1)
        : 0.0;

    for (var i = 0; i < history.length; i++) {
      final x = history.length == 1 ? size.width : i * stepX;
      final normalized = (history[i] / scale).clamp(0.0, 1.0);
      final y = size.height - normalized * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _FpsGraphPainter oldDelegate) {
    return oldDelegate.history != history ||
        oldDelegate.color != color ||
        oldDelegate.dividerColor != dividerColor;
  }
}

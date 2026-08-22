import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Applications per day over the last 30 days (§8.3).
///
/// Bars rather than the curve the finance page uses: these are whole-number
/// counts on discrete days, most of them zero, and a smoothed line would
/// invent applications on the days between two spikes.
class JobsSparkline extends StatelessWidget {
  const JobsSparkline({super.key, required this.counts, this.color});

  final List<int> counts;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomPaint(
      painter: _JobsSparklinePainter(
        counts: counts,
        color: color ?? theme.colorScheme.primary,
      ),
    );
  }
}

class _JobsSparklinePainter extends CustomPainter {
  const _JobsSparklinePainter({required this.counts, required this.color});

  final List<int> counts;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (counts.isEmpty || size.width <= 0) return;

    final maxCount = counts.fold(0, math.max);
    // The baseline is drawn whether or not anything happened, so thirty empty
    // days read as "nothing yet" rather than as a broken chart.
    final baselineY = size.height - 0.5;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      Paint()..color = color.withValues(alpha: 0.18),
    );
    if (maxCount == 0) return;

    final slot = size.width / counts.length;
    final barWidth = math.max(1.5, math.min(4.0, slot - 1.5));
    final usableHeight = size.height - 2;
    final paint = Paint()..color = color;

    for (var i = 0; i < counts.length; i++) {
      if (counts[i] == 0) continue;
      // Every non-zero day gets at least a visible stub: on a month with one
      // busy day, a proportional bar for a single application would round away
      // to nothing.
      final height = math.max(2.0, usableHeight * (counts[i] / maxCount));
      final left = slot * i + (slot - barWidth) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, baselineY - height, barWidth, height),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _JobsSparklinePainter oldDelegate) =>
      !listEquals(oldDelegate.counts, counts) || oldDelegate.color != color;
}

/// One stage's share of the applications feeding into it.
typedef JobsSankeyFlow = ({String status, int count, Color color});

/// Applications → current stage, as a single-hop flow band (§8.4).
///
/// Deliberately one hop. The Sankey is built from each application's *current*
/// status, and the timeline is not consulted, so there are no real
/// stage-to-stage edges to draw — a multi-hop diagram here would be invented.
/// What this does show honestly is how the pile divides: a trunk on the left
/// carrying every application, splitting into one ribbon per stage whose
/// thickness is that stage's share.
class JobsSankey extends StatelessWidget {
  const JobsSankey({super.key, required this.flows});

  final List<JobsSankeyFlow> flows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (flows.isEmpty) {
      return Center(
        child: Text(
          'No applications yet',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    return CustomPaint(
      painter: _JobsSankeyPainter(
        flows: flows,
        trunkColor: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _JobsSankeyPainter extends CustomPainter {
  const _JobsSankeyPainter({required this.flows, required this.trunkColor});

  final List<JobsSankeyFlow> flows;
  final Color trunkColor;

  static const _trunkWidth = 6.0;
  static const _nodeWidth = 6.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final total = flows.fold(0, (sum, flow) => sum + flow.count);
    if (total == 0 || size.width <= 0 || size.height <= 0) return;

    // A single populated stage is a valid, if degenerate, Sankey (§8.4): one
    // ribbon spanning the full height. Nothing special-cases it — the
    // proportional maths already produces exactly that.
    final gaps = _gap * (flows.length - 1);
    final ribbonHeight = math.max(0.0, size.height - gaps);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, _trunkWidth, size.height),
        const Radius.circular(2),
      ),
      Paint()..color = trunkColor.withValues(alpha: 0.35),
    );

    final left = _trunkWidth;
    final right = size.width - _nodeWidth;
    if (right <= left) return;

    var sourceY = 0.0;
    var targetY = 0.0;
    for (final flow in flows) {
      final share = flow.count / total;
      // The ribbon leaves the trunk at the same share of the trunk's height it
      // arrives at on the right, so the two ends of a flow are the same
      // thickness and the band reads as one continuous quantity.
      final sourceHeight = size.height * share;
      final targetHeight = ribbonHeight * share;

      final path = Path()
        ..moveTo(left, sourceY)
        ..cubicTo(
          left + (right - left) * 0.5,
          sourceY,
          left + (right - left) * 0.5,
          targetY,
          right,
          targetY,
        )
        ..lineTo(right, targetY + targetHeight)
        ..cubicTo(
          left + (right - left) * 0.5,
          targetY + targetHeight,
          left + (right - left) * 0.5,
          sourceY + sourceHeight,
          left,
          sourceY + sourceHeight,
        )
        ..close();
      canvas.drawPath(path, Paint()..color = flow.color.withValues(alpha: 0.4));

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(right, targetY, _nodeWidth, targetHeight),
          const Radius.circular(2),
        ),
        Paint()..color = flow.color,
      );

      sourceY += sourceHeight;
      targetY += targetHeight + _gap;
    }
  }

  @override
  bool shouldRepaint(covariant _JobsSankeyPainter oldDelegate) =>
      !listEquals(oldDelegate.flows, flows) ||
      oldDelegate.trunkColor != trunkColor;
}

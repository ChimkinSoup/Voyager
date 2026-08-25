import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';

/// Width the stat popup sits at when its value fits.
const double statPopupWidth = 260.0;

/// How wide it is allowed to grow for a value that doesn't. The kilometres
/// figure runs to eleven digits, well past [statPopupWidth] at the value
/// line's type size.
const double statPopupMaxWidth = 420.0;

const EdgeInsets _padding = EdgeInsets.fromLTRB(20, 18, 20, 20);

/// Popup content for a single blossom: the stat's title, its current value,
/// and (if there is one) a footnote explaining the assumption behind it.
class BlossomStatPopup extends ConsumerWidget {
  const BlossomStatPopup({super.key, required this.stat, required this.accentColor});

  final LifeStat stat;
  final Color accentColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final cached = ref.watch(lifeTrackerStatsProvider).valueOrNull;

    final resolved = resolveLifeStat(
      stat: stat,
      birthDate: settings?.birthDate,
      now: DateTime.now(),
      tasksConquered: cached?.tasksConquered ?? 0,
      lifetimeMood: cached?.lifetimeMood,
    );

    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: accentColor,
    );
    final secondaryStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: accentColor.withValues(alpha: 0.7),
    );

    // The value is the one line that must not wrap: breaking a number across
    // two lines makes it unreadable. Measure it and widen the popup to fit
    // instead. Placeholder sentences are prose and wrap happily, and the
    // title and footnote keep wrapping either way.
    final valueWidth = resolved.isPlaceholder
        ? 0.0
        : math.max(
            _lineWidth(context, resolved.value, valueStyle),
            resolved.secondaryValue == null
                ? 0.0
                : _lineWidth(context, resolved.secondaryValue!, secondaryStyle),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          math.max(valueWidth + _padding.horizontal, statPopupWidth),
          constraints.maxWidth,
        );
        return SizedBox(
          width: width,
          child: Padding(
            padding: _padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  resolved.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Text(resolved.value, style: valueStyle),
                if (resolved.secondaryValue != null) ...[
                  const SizedBox(height: 2),
                  Text(resolved.secondaryValue!, style: secondaryStyle),
                ],
                if (resolved.footnote != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    resolved.footnote!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Width [text] wants on a single line, at the same scale it will be painted.
double _lineWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

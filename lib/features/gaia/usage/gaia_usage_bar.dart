import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_limits.dart';

/// Every usage window of an account as a bar (§6.2): the ring's tooltip on
/// the composer, and the Gaia page's Setup tab.
List<Widget> gaiaUsageBars(GaiaUsage usage) => [
  for (final (name, window) in gaiaUsageWindows(usage))
    GaiaUsageBar(name: name, window: window),
];

/// Every usage window of an account, with its name: the bars, and `/usage`.
List<(String, GaiaUsageWindow?)> gaiaUsageWindows(GaiaUsage usage) => [
  ('5-hour', usage.fiveHour),
  ('Weekly', usage.weekly),
  for (final window in usage.weeklyModels) ('Weekly, ${window.model}', window),
];

/// When [window] resets, or why that isn't known.
String gaiaUsageDetail(GaiaUsageWindow? window) {
  final resets = window?.resetsAt;
  if (window == null) return 'Unknown';
  if (resets == null) return 'Not started';
  final at = gaiaResetTime(resets);
  // Its next reset isn't known until it's read again.
  return resets.isAfter(DateTime.now()) ? 'Resets $at' : 'Reset at $at';
}

/// One usage window: its name and share used over a bar, and when it resets.
class GaiaUsageBar extends StatelessWidget {
  const GaiaUsageBar({super.key, required this.name, required this.window});

  final String name;
  final GaiaUsageWindow? window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final window = this.window;
    final used = window?.usedNow ?? 0;
    final detail = gaiaUsageDetail(window);
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, style: theme.textTheme.bodySmall)),
              if (window != null)
                Text(
                  '${(used * 100).round()}%',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: used,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            backgroundColor: Colors.white.withValues(alpha: 0.15),
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 4),
          Text(detail, style: muted),
        ],
      ),
    );
  }
}

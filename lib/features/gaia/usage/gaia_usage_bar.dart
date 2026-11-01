import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_limits.dart';

/// Every usage window of an account as a bar (§6.2): the ring's tooltip on
/// the composer, and the Gaia page's Setup tab.
List<Widget> gaiaUsageBars(GaiaUsage usage) => [
  GaiaUsageBar(name: '5-hour', window: usage.fiveHour),
  GaiaUsageBar(name: 'Weekly', window: usage.weekly),
  for (final window in usage.weeklyModels)
    GaiaUsageBar(name: 'Weekly, ${window.model}', window: window),
];

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
    final resets = window?.resetsAt;
    final String detail;
    if (window == null) {
      detail = 'Unknown';
    } else if (resets == null) {
      detail = 'Not started';
    } else {
      final at = gaiaResetTime(resets);
      // Its next reset isn't known until it's read again.
      detail = resets.isAfter(DateTime.now()) ? 'Resets $at' : 'Reset at $at';
    }
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

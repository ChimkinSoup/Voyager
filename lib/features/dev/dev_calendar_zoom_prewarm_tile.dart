import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/calendar/month_zoom_prewarm_tracker.dart';

class DevCalendarZoomPrewarmSection extends ConsumerWidget {
  const DevCalendarZoomPrewarmSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devSettings = ref.watch(devSettingsProvider);
    final prewarm = ref.watch(monthZoomPrewarmTrackerProvider).status;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Show calendar zoom prewarm'),
          subtitle: const Text(
            'Checklist for the full year→month transition pipeline',
          ),
          value: devSettings.showCalendarZoomPrewarm,
          onChanged: (value) {
            unawaited(
              ref.read(devSettingsProvider).setShowCalendarZoomPrewarm(value),
            );
          },
        ),
        if (devSettings.showCalendarZoomPrewarm) ...[
          const SizedBox(height: 8),
          _CalendarZoomPrewarmSummary(status: prewarm),
          const SizedBox(height: 12),
          _CalendarZoomPrewarmChecklist(status: prewarm),
        ],
      ],
    );
  }
}

class CalendarZoomPrewarmOverlay extends ConsumerWidget {
  const CalendarZoomPrewarmOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(devSettingsProvider).showCalendarZoomPrewarm) {
      return const SizedBox.shrink();
    }

    final prewarm = ref.watch(monthZoomPrewarmTrackerProvider).status;
    final theme = Theme.of(context);

    return Positioned(
      left: 88,
      bottom: 72,
      child: Material(
        elevation: 6,
        color: theme.colorScheme.surface.withValues(alpha: 0.96),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.dividerColor),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _CalendarZoomPrewarmSummary(status: prewarm, compact: true),
          ),
        ),
      ),
    );
  }
}

class _CalendarZoomPrewarmSummary extends StatelessWidget {
  const _CalendarZoomPrewarmSummary({
    required this.status,
    this.compact = false,
  });

  final MonthZoomPrewarmStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readyColor = status.isFullyPrewarmed
        ? const Color(0xFF81C784)
        : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact)
          Text(
            'Calendar zoom prewarm',
            style: theme.textTheme.titleSmall,
          ),
        if (!compact) const SizedBox(height: 8),
        Text(
          status.isFullyPrewarmed ? 'Fully pre-warmed' : status.summary,
          style: compact
              ? theme.textTheme.bodySmall
              : theme.textTheme.bodyMedium?.copyWith(color: readyColor),
        ),
        if (status.totalCount > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${status.passedCount}/${status.totalCount} checks passed',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: compact ? 4 : 6,
              value: status.totalCount == 0
                  ? null
                  : status.passedCount / status.totalCount,
              backgroundColor: theme.colorScheme.outline.withValues(alpha: 0.25),
              color: readyColor,
            ),
          ),
        ],
      ],
    );
  }
}

class _CalendarZoomPrewarmChecklist extends StatelessWidget {
  const _CalendarZoomPrewarmChecklist({required this.status});

  final MonthZoomPrewarmStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (status.checks.isEmpty) {
      return Text(
        status.summary,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: status.checks.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          color: theme.dividerColor,
        ),
        itemBuilder: (context, index) {
          final check = status.checks[index];
          final color = check.passed
              ? const Color(0xFF81C784)
              : theme.colorScheme.onSurface.withValues(alpha: 0.55);

          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              check.passed ? Icons.check_circle : Icons.radio_button_unchecked,
              color: color,
              size: 20,
            ),
            title: Text(check.label, style: theme.textTheme.bodyMedium),
            subtitle: check.detail == null
                ? null
                : Text(
                    check.detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

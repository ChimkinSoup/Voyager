import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';

class DevCalendarDebugSection extends ConsumerWidget {
  const DevCalendarDebugSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devSettings = ref.watch(devSettingsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Calendar instant view switch'),
          subtitle: const Text(
            'Show Month and Year buttons in the calendar sidebar to skip zoom animations',
          ),
          value: devSettings.showCalendarInstantViewSwitch,
          onChanged: (value) {
            unawaited(
              ref
                  .read(devSettingsProvider)
                  .setShowCalendarInstantViewSwitch(value),
            );
          },
        ),
        SwitchListTile(
          title: const Text('Slow calendar animations'),
          subtitle: const Text(
            'Play month/year/week morph animations at 10× duration for debugging',
          ),
          value: devSettings.slowCalendarAnimations,
          onChanged: (value) {
            unawaited(
              ref.read(devSettingsProvider).setSlowCalendarAnimations(value),
            );
          },
        ),
        ListTile(
          title: const Text('Analytics Calendar Month Override'),
          subtitle: const Text('Force the heatmap calendar to a specific layout size'),
          trailing: DropdownButton<DevAnalyticsMonthOverride>(
            value: ref.watch(devAnalyticsMonthOverrideProvider),
            onChanged: (v) {
              if (v != null) {
                ref.read(devAnalyticsMonthOverrideProvider.notifier).state = v;
              }
            },
            items: const [
              DropdownMenuItem(value: DevAnalyticsMonthOverride.none, child: Text('None (Current)')),
              DropdownMenuItem(value: DevAnalyticsMonthOverride.fourRows, child: Text('4 rows (Feb 2026)')),
              DropdownMenuItem(value: DevAnalyticsMonthOverride.fiveRows, child: Text('5 rows (Jul 2026)')),
              DropdownMenuItem(value: DevAnalyticsMonthOverride.sixRows, child: Text('6 rows (May 2026)')),
            ],
          ),
        ),
      ],
    );
  }
}

enum DevAnalyticsMonthOverride {
  none,
  fourRows,
  fiveRows,
  sixRows,
}

final devAnalyticsMonthOverrideProvider = StateProvider<DevAnalyticsMonthOverride>(
  (ref) => DevAnalyticsMonthOverride.none,
);

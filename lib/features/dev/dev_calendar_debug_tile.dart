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
      ],
    );
  }
}

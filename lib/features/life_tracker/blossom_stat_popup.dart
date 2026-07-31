import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';

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

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            resolved.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            resolved.value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: accentColor,
            ),
          ),
          if (resolved.footnote != null) ...[
            const SizedBox(height: 10),
            Text(
              resolved.footnote!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

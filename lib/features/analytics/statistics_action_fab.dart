import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/features/analytics/statistics_entry_modal.dart';

/// A floating action button placed on the Journal page.
///
/// When [pendingStatEntriesProvider] > 0 (i.e. there are daily trackers with
/// no entry for today) the button shows an accent-coloured soft glow and a red badge
/// to draw the user's attention. Tapping it opens [StatisticsEntryModal].
class StatisticsActionFab extends ConsumerWidget {
  const StatisticsActionFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingStatEntriesProvider);
    final accent = Theme.of(context).colorScheme.primary;
    final pending = pendingAsync.valueOrNull ?? 0;

    final glowColor = accent.withValues(alpha: pending > 0 ? popupGlowAlpha : 0.0);

    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          if (pending > 0)
            BoxShadow(
              color: glowColor,
              blurRadius: 14.0,
              spreadRadius: 4.0,
            ),
        ],
      ),
      child: FloatingActionButton(
        mini: true,
        tooltip: pending > 0
            ? 'Log today\'s stats ($pending pending)'
            : 'Log stats',
        onPressed: () async {
          await showStatisticsEntryModal(context, ref);
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(PhosphorIconsRegular.chartBar, size: 18),
            if (pending > 0)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

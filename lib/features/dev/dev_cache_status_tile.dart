import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/cache_status.dart';

class DevCacheStatusSection extends ConsumerWidget {
  const DevCacheStatusSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devSettings = ref.watch(devSettingsProvider);
    final snapshot = ref.watch(cacheStatusSnapshotProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Show cache status'),
          subtitle: const Text(
            'Overlay progress while data loads, plus a detailed list here',
          ),
          value: devSettings.showCacheStatus,
          onChanged: (value) {
            unawaited(ref.read(devSettingsProvider).setShowCacheStatus(value));
          },
        ),
        if (devSettings.showCacheStatus) ...[
          const SizedBox(height: 8),
          _CacheStatusSummary(snapshot: snapshot),
          const SizedBox(height: 12),
          _CacheStatusItemList(snapshot: snapshot),
        ],
      ],
    );
  }
}

class CacheStatusOverlay extends ConsumerWidget {
  const CacheStatusOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(devSettingsProvider).showCacheStatus) {
      return const SizedBox.shrink();
    }

    final snapshot = ref.watch(cacheStatusSnapshotProvider);
    final theme = Theme.of(context);

    return Positioned(
      left: 88,
      bottom: 12,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Cache status',
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                _CacheStatusSummary(snapshot: snapshot, compact: true),
                if (snapshot.loading > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.loading} in progress',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CacheStatusSummary extends StatelessWidget {
  const _CacheStatusSummary({
    required this.snapshot,
    this.compact = false,
  });

  final CacheStatusSnapshot snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loadedLabel =
        '${snapshot.loaded}/${snapshot.total} cached (${snapshot.loadedPercent}%)';
    final attemptedLabel =
        '${snapshot.attempted}/${snapshot.total} attempted (${snapshot.attemptedPercent}%)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact) ...[
          Text(loadedLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            attemptedLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
        ] else
          Text(
            loadedLabel,
            style: theme.textTheme.bodySmall,
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: compact ? 4 : 6,
            value: snapshot.total == 0 ? null : snapshot.loadedFraction,
            backgroundColor: theme.colorScheme.outline.withValues(alpha: 0.25),
          ),
        ),
        if (!compact && snapshot.failed > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${snapshot.failed} failed',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _CacheStatusItemList extends StatelessWidget {
  const _CacheStatusItemList({required this.snapshot});

  final CacheStatusSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: snapshot.items.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          color: theme.dividerColor,
        ),
        itemBuilder: (context, index) {
          final item = snapshot.items[index];
          final color = cacheStateColor(item.state, theme.colorScheme);

          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(item.label, style: theme.textTheme.bodyMedium),
            subtitle: item.detail == null
                ? null
                : Text(
                    item.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
            trailing: Text(
              cacheStateLabel(item.state),
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          );
        },
      ),
    );
  }
}

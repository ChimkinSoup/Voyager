import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';

/// The "Subscription & Bill Radar" panel: an active roster of recurring costs
/// ordered as a countdown to their next due date. Shown in the finance
/// dashboard's right sidebar (and stacked below the ledger on narrow screens).
class BillRadarPanel extends ConsumerWidget {
  const BillRadarPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final subscriptionsAsync = ref.watch(subscriptionsProvider);
    final showAnnual = ref
            .watch(settingsProvider)
            .valueOrNull
            ?.showAnnualizedSubscriptionCost ??
        false;
    final subscriptions = subscriptionsAsync.valueOrNull ?? const [];

    // Sum of monthly-equivalent cost across every subscription.
    final monthlyEquivalentCents = subscriptions.fold<int>(
      0,
      (sum, s) => sum + (s.annualCents / 12).round(),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsRegular.broadcast,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Subscription & Bill Radar',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              GlassButton(
                icon: const Icon(PhosphorIconsRegular.plus, size: 16),
                dense: true,
                tooltip: 'Add subscription',
                onPressed: () => showSubscriptionModal(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (subscriptions.isEmpty)
            const _EmptyRadar()
          else ...[
            for (final subscription in subscriptions)
              _SubscriptionTile(
                subscription: subscription,
                showAnnual: showAnnual,
              ),
            const SizedBox(height: 8),
            Divider(
              height: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${subscriptions.length} '
                  'subscription${subscriptions.length == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '≈ ${formatCents(monthlyEquivalentCents)}/mo',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionTile extends ConsumerWidget {
  const _SubscriptionTile({
    required this.subscription,
    required this.showAnnual,
  });

  final Subscription subscription;
  final bool showAnnual;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = Color(subscription.colorValue);
    final daysUntil = subscription.daysUntilDue();

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () =>
          showSubscriptionModal(context, ref, existing: subscription),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Timeline rail: dot with a connector line to the next tile.
            SizedBox(
              width: 14,
              child: Column(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    subscription.name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _dueLabel(daysUntil),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _dueColor(theme, daysUntil),
                      fontWeight: daysUntil <= 3
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatCents(subscription.amountCents),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  billingPeriodLabel(subscription.period).toLowerCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.7),
                  ),
                ),
                if (showAnnual)
                  Text(
                    '${formatCents(subscription.annualCents)}/yr',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _dueLabel(int days) {
    if (days <= 0) return 'Due today';
    if (days == 1) return 'Due tomorrow';
    return 'Due in $days days';
  }

  Color _dueColor(ThemeData theme, int days) {
    if (days <= 1) return theme.colorScheme.error;
    if (days <= 3) return theme.colorScheme.primary;
    return theme.colorScheme.onSurfaceVariant;
  }
}

class _EmptyRadar extends StatelessWidget {
  const _EmptyRadar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(
            PhosphorIconsRegular.broadcast,
            size: 28,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            'No recurring costs yet.\nTap + to track a subscription or bill.',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

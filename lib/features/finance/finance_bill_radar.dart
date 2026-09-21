import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_soft_delete.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';

/// The "Subscription & Bill Radar" panel: an active roster of recurring costs
/// ordered as a countdown to their next due date. Shown in the finance
/// dashboard's right sidebar (and stacked below the ledger on narrow screens).
class BillRadarPanel extends ConsumerWidget {
  const BillRadarPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final subscriptionsAsync = ref.watch(subscriptionsProvider);
    final showAnnual =
        ref
            .watch(settingsProvider)
            .valueOrNull
            ?.showAnnualizedSubscriptionCost ??
        false;
    // Ordered here rather than in the repository: nextDue() is relative to
    // now, and subscriptionsProvider is keepAlive, so an order baked at fetch
    // time decays — on a long desktop session a bill that has just come due
    // stays sorted last while its own tile correctly reads "Due today".
    final now = DateTime.now();
    final subscriptions = [
      ...(subscriptionsAsync.valueOrNull ?? const <Subscription>[]),
    ]..sort((a, b) => a.nextDue(now).compareTo(b.nextDue(now)));

    // Sum of monthly-equivalent cost across every subscription.
    final monthlyEquivalentCents = subscriptions.fold<int>(
      0,
      (sum, s) => sum + (s.annualCents / 12).round(),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.25,
        ),
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
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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

  /// Soft-deletes the bill and offers an undo.
  ///
  /// The overlay and container are resolved up front: the delete unmounts this
  /// tile, and `ref` throws once that happens — see [deleteSubscriptionWithUndo].
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    await deleteSubscriptionWithUndo(
      overlay: Overlay.of(context, rootOverlay: true),
      container: ProviderScope.containerOf(ref.context, listen: false),
      repo: ref.read(financeRepositoryProvider),
      subscription: subscription,
    );
  }

  /// Files the same bill again, due today.
  ///
  /// Today rather than the original's anchor: a duplicate is almost always a
  /// second bill that happens to look like this one, and an anchor copied from
  /// a bill paid three weeks ago would open the copy already overdue.
  Future<void> _duplicate(WidgetRef ref) async {
    final repo = ref.read(financeRepositoryProvider);
    final container = ProviderScope.containerOf(ref.context, listen: false);
    final now = utcNow();
    final today = DateTime.now();
    await repo.upsertSubscription(
      Subscription(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        name: subscription.name,
        amountCents: subscription.amountCents,
        period: subscription.period,
        anchorDueDate: DateTime(today.year, today.month, today.day),
        colorValue: subscription.colorValue,
        note: subscription.note,
      ),
    );
    container.invalidate(subscriptionsProvider);
  }

  /// Logs the bill as an expense and, only if that save lands, rolls its due
  /// date on to the next cycle.
  ///
  /// The advance is tied to the save rather than to the menu press so a
  /// cancelled sheet leaves the radar exactly as it was — the bill is still
  /// due, because nothing was paid.
  Future<void> _logPayment(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(financeRepositoryProvider);
    final container = ProviderScope.containerOf(ref.context, listen: false);
    final sub = subscription;

    await showFinanceTransactionModal(
      context,
      ref,
      draft: FinanceTransactionDraft(
        type: TransactionType.expense,
        amountCents: sub.amountCents,
        // No tags invented from the name: a bill is not a tag, and a guessed
        // one would quietly land in every budget and breakdown built on tags.
        // The bill is who got paid, so it is the store; the note is left for
        // the user.
        origin: sub.name,
        occurredAt: DateTime.now(),
      ),
      onSaved: () async {
        // The settled occurrence is recorded; the anchor is left alone. Moving
        // the anchor onto the paid date instead would clamp a bill due the
        // 31st onto Feb 28 the first February it was paid, permanently.
        //
        // Always the upcoming occurrence, whatever date the user put on the
        // expense: the menu press is what says "this bill is paid", and
        // reading the cycle off an editable field would make Log payment
        // silently do nothing whenever the expense was backdated.
        await repo.upsertSubscription(
          sub.copyWith(
            paidThroughDate: sub.nextDue(DateTime.now()),
            updatedAt: utcNow(),
            version: sub.version + 1,
          ),
        );
        container.invalidate(subscriptionsProvider);
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = paletteColor(subscription.colorValue, context);
    final daysUntil = subscription.daysUntilDue();

    return ContextMenuRegion(
      // Built on right-click rather than eagerly: the radar rebuilds wholesale
      // whenever a bill changes, and these entries are only ever looked at by
      // the tile actually being clicked.
      itemsBuilder: () => [
        ContextMenuItem(
          label: 'Edit',
          icon: PhosphorIconsRegular.pencilSimple,
          onTap: () =>
              showSubscriptionModal(context, ref, existing: subscription),
        ),
        ContextMenuItem(
          label: 'Log payment',
          icon: PhosphorIconsRegular.receipt,
          onTap: () => _logPayment(context, ref),
        ),
        ContextMenuItem(
          label: 'Duplicate',
          icon: PhosphorIconsRegular.copy,
          onTap: () => _duplicate(ref),
        ),
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => _delete(context, ref),
        ),
      ],
      child: InkWell(
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
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
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
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    billingPeriodLabel(subscription.period).toLowerCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                  if (showAnnual)
                    Text(
                      '${formatCents(subscription.annualCents)}/yr',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
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

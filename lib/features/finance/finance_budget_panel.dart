import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_budget_modal.dart';
import 'package:voyager/features/finance/finance_soft_delete.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart'
    show kIncomeGreen;

/// The "Budgets & Pacing" panel: tag-based soft limits, each drawn as a
/// progress bar with a pace marker showing where spending *should* be this far
/// into the month.
class BudgetPanel extends ConsumerWidget {
  const BudgetPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final budgets = ref.watch(budgetsProvider).valueOrNull ?? const [];
    final now = DateTime.now();
    final transactions = settledTransactions(
      ref.watch(transactionsProvider).valueOrNull ?? const [],
      now,
    );
    final tagColors = ref.watch(tagColorsProvider).valueOrNull ?? const {};

    final pace = monthPaceFraction(now);
    final daysLeft = daysInMonth(now.year, now.month) - now.day;

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
                PhosphorIconsRegular.target,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Budgets & Pacing',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              GlassButton(
                icon: const Icon(PhosphorIconsRegular.plus, size: 16),
                dense: true,
                tooltip: 'Add budget',
                onPressed: () => showBudgetModal(context, ref),
              ),
            ],
          ),
          if (budgets.isEmpty)
            const _EmptyBudgets()
          else ...[
            Text(
              daysLeft == 0
                  ? 'Last day of the month'
                  : '$daysLeft day${daysLeft == 1 ? '' : 's'} left this month',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            for (final budget in budgets)
              _BudgetRow(
                budget: budget,
                spentCents: budgetSpentCents(transactions, budget.tag, now),
                pace: pace,
                tagColorValue: tagColors[budget.tag],
              ),
          ],
        ],
      ),
    );
  }
}

class _BudgetRow extends ConsumerWidget {
  const _BudgetRow({
    required this.budget,
    required this.spentCents,
    required this.pace,
    this.tagColorValue,
  });

  final Budget budget;
  final int spentCents;
  final double pace;
  final int? tagColorValue;

  /// Soft-deletes the budget and offers an undo. See [deleteBudgetWithUndo]
  /// for why the overlay and container are resolved before the delete.
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    await deleteBudgetWithUndo(
      overlay: Overlay.of(context, rootOverlay: true),
      container: ProviderScope.containerOf(ref.context, listen: false),
      repo: ref.read(financeRepositoryProvider),
      budget: budget,
    );
  }

  /// Sends the user to the ledger, filtered to this budget's tag.
  ///
  /// All-time rather than this month: the pacing bar above already answers
  /// "how am I doing this month", so the question left over is the one the
  /// bar can't show — what the spending on this tag actually looks like.
  void _viewExpenses(WidgetRef ref) {
    ref.read(financeLedgerTagFilterProvider.notifier).state = budget.tag;
    ref
        .read(financeUiPrefsProvider.notifier)
        .setViewMode(FinanceViewMode.ledger);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = budgetStatus(
      spentCents: spentCents,
      limitCents: budget.limitCents,
      pace: pace,
    );
    final statusColor = switch (status) {
      BudgetStatus.onTrack => kIncomeGreen,
      BudgetStatus.aheadOfPace => theme.colorScheme.primary,
      BudgetStatus.overBudget => theme.colorScheme.error,
    };
    final tagColor = tagColorValue != null
        ? Color(tagColorValue!)
        : theme.colorScheme.onSurfaceVariant;
    final remaining = budget.limitCents - spentCents;
    final spentFraction =
        budget.limitCents <= 0 ? 0.0 : spentCents / budget.limitCents;

    return ContextMenuRegion(
      // Built on right-click rather than eagerly, like the ledger rows: the
      // panel rebuilds wholesale whenever a transaction lands.
      itemsBuilder: () => [
        ContextMenuItem(
          label: 'Edit',
          icon: PhosphorIconsRegular.pencilSimple,
          onTap: () => showBudgetModal(context, ref, existing: budget),
        ),
        ContextMenuItem(
          label: 'View expenses',
          icon: PhosphorIconsRegular.receipt,
          onTap: () => _viewExpenses(ref),
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
        onTap: () => showBudgetModal(context, ref, existing: budget),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: tagColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
                    ),
                    child: Text(
                      '#${budget.tag}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: tagColor,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${formatCents(spentCents)} / ${formatCents(budget.limitCents)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _PacingBar(
                spentFraction: spentFraction,
                pace: pace,
                color: statusColor,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    switch (status) {
                      BudgetStatus.onTrack => 'On track',
                      BudgetStatus.aheadOfPace => 'Ahead of pace',
                      BudgetStatus.overBudget => 'Over budget',
                    },
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    remaining >= 0
                        ? '${formatCents(remaining)} left'
                        : '${formatCents(remaining.abs())} over',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
}

/// A progress bar for spend-against-limit, overlaid with a vertical marker at
/// the month's elapsed fraction. Fill left of the marker means spending is
/// behind pace; fill past it means it's running ahead.
class _PacingBar extends StatelessWidget {
  const _PacingBar({
    required this.spentFraction,
    required this.pace,
    required this.color,
  });

  final double spentFraction;
  final double pace;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fill = (spentFraction.clamp(0.0, 1.0)) * width;
        const markerWidth = 2.0;
        // num.clamp asserts lowerLimit <= upperLimit, so the second clamp
        // throws once the track is narrower than the marker — which a
        // LayoutBuilder legitimately reports mid-layout (a collapsing
        // sidebar, a zero-width Expanded during an animation).
        final markerLeft = width <= markerWidth
            ? 0.0
            : (pace.clamp(0.0, 1.0) * width).clamp(0.0, width - markerWidth);

        return SizedBox(
          height: 10,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Track
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              // Spent fill
              Container(
                width: fill,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              // Pace marker
              Positioned(
                left: markerLeft,
                top: -2,
                bottom: -2,
                width: markerWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyBudgets extends StatelessWidget {
  const _EmptyBudgets();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(
            PhosphorIconsRegular.target,
            size: 28,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            'No budgets yet.\nTap + to cap spending on a tag.',
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

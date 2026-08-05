import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_allocate_modal.dart';
import 'package:voyager/features/finance/finance_goal_modal.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart'
    show kIncomeGreen;
import 'package:voyager/features/finance/geometric_progress_ring.dart';
import 'package:voyager/core/layout/touch_target.dart';

/// Savings buckets shown as geometric progress rings that fill as the user
/// allocates money into them.
class FinanceGoalsView extends ConsumerWidget {
  const FinanceGoalsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final goals = ref.watch(savingsGoalsProvider).valueOrNull ?? const [];
    final allocations =
        ref.watch(goalAllocationsProvider).valueOrNull ?? const [];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 880;
        final horizontal = wide ? 20.0 : 16.0;

        if (goals.isEmpty) {
          return ListView(
            padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 96),
            children: [_EmptyGoals(onCreate: () => showGoalModal(context, ref))],
          );
        }

        final totalTarget =
            goals.fold<int>(0, (s, g) => s + g.targetCents);
        final totalSaved = goals.fold<int>(
          0,
          (s, g) => s + goalAllocatedCents(allocations, g.id),
        );
        final completed = goals
            .where((g) =>
                goalAllocatedCents(allocations, g.id) >= g.targetCents)
            .length;

        return ListView(
          padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 96),
          children: [
            // Summary strip
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsRegular.flag,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$completed of ${goals.length} goal'
                      '${goals.length == 1 ? '' : 's'} reached',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${formatCents(totalSaved)} of ${formatCents(totalTarget)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    icon: const Icon(PhosphorIconsRegular.plus, size: 16),
                    dense: true,
                    tooltip: 'New goal',
                    onPressed: () => showGoalModal(context, ref),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final goal in goals)
                  _GoalCard(
                    goal: goal,
                    allocatedCents: goalAllocatedCents(allocations, goal.id),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _GoalCard extends ConsumerWidget {
  const _GoalCard({required this.goal, required this.allocatedCents});

  final SavingsGoal goal;
  final int allocatedCents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = Color(goal.colorValue);
    final progress = goalProgress(allocatedCents, goal.targetCents);
    final complete = allocatedCents >= goal.targetCents;
    final remaining = goal.targetCents - allocatedCents;
    final daysLeft = goal.daysUntilTarget();

    return SizedBox(
      width: 220,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: complete
                ? color.withValues(alpha: 0.5)
                : theme.colorScheme.outline.withValues(alpha: 0.12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    goal.name,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 14),
                  padding: EdgeInsets.zero,
                  constraints: kMinTouchTarget,
                  tooltip: 'Edit goal',
                  onPressed: () =>
                      showGoalModal(context, ref, existing: goal),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: GeometricProgressRing(
                progress: progress,
                color: color,
                size: 132,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(progress * 100).round()}%',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: complete ? color : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (complete)
                      Icon(
                        PhosphorIconsFill.checkCircle,
                        size: 14,
                        color: color,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${formatCents(allocatedCents)} of ${formatCents(goal.targetCents)}',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              complete
                  ? 'Goal reached'
                  : '${formatCents(remaining)} to go',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: complete ? kIncomeGreen : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (daysLeft != null) ...[
              const SizedBox(height: 4),
              Text(
                _milestoneLabel(daysLeft, goal.targetDate!, complete),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: !complete && daysLeft < 0
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                ),
              ),
            ],
            const SizedBox(height: 12),
            GlassButton(
              onPressed: () => showAllocateModal(context, ref, goal: goal),
              icon: const Icon(PhosphorIconsRegular.plus, size: 14),
              label: 'Add funds',
              dense: true,
              color: color,
            ),
          ],
        ),
      ),
    );
  }

  String _milestoneLabel(int days, DateTime target, bool complete) {
    final formatted = DateFormat('MMM d, yyyy').format(target);
    if (complete) return 'Target was $formatted';
    if (days < 0) return '${-days} days overdue';
    if (days == 0) return 'Due today';
    if (days == 1) return 'Due tomorrow';
    return '$days days left · $formatted';
  }
}

class _EmptyGoals extends StatelessWidget {
  const _EmptyGoals({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        children: [
          Icon(
            PhosphorIconsRegular.flag,
            size: 36,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'No savings goals yet',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Create a bucket like "Japan trip" or "Emergency fund", then '
            'allocate money into it to watch its ring fill up.',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          GlassButton(
            onPressed: onCreate,
            icon: const Icon(PhosphorIconsRegular.plus, size: 16),
            label: 'New goal',
          ),
        ],
      ),
    );
  }
}

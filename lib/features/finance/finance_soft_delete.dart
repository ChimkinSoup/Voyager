import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Soft-deletes [subscription] and offers an undo.
///
/// [overlay] and [container] must both be resolved *before* the call: deleting
/// the bill unmounts the tile that raised the menu, and the toast — and the
/// restore behind it — has to outlive that. Same contract the ledger row's
/// delete keeps.
Future<bool> deleteSubscriptionWithUndo({
  required OverlayState overlay,
  required ProviderContainer container,
  required FinanceRepository repo,
  required Subscription subscription,
}) async {
  return softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(subscription.name, fallback: 'bill'),
    delete: () async {
      await repo.softDeleteSubscription(subscription.id);
      container.invalidate(subscriptionsProvider);
    },
    restore: () async {
      // Rebuilt rather than copyWith'd: copyWith reads
      // `deletedAt ?? this.deletedAt`, so it cannot clear a tombstone.
      final current = await repo.getSubscription(subscription.id);
      abortIfAlreadyRestored(
        found: current != null,
        deletedAt: current?.deletedAt,
      );
      await repo.upsertSubscription(
        Subscription(
          id: subscription.id,
          createdAt: subscription.createdAt,
          updatedAt: utcNow(),
          // Resolved against disk rather than against the snapshot — see
          // [restoreVersionFrom].
          version: restoreVersionFrom(
            preDeleteVersion: subscription.version,
            currentVersion: current?.version,
          ),
          name: subscription.name,
          amountCents: subscription.amountCents,
          period: subscription.period,
          anchorDueDate: subscription.anchorDueDate,
          paidThroughDate: subscription.paidThroughDate,
          colorValue: subscription.colorValue,
          note: subscription.note,
          store: subscription.store,
        ),
      );
      container.invalidate(subscriptionsProvider);
    },
  );
}

/// Soft-deletes [category] and offers an undo, like a budget or a bill
/// (BUG-120). See [deleteSubscriptionWithUndo] for why the overlay and
/// container are passed in rather than looked up.
Future<bool> deleteCategoryWithUndo({
  required OverlayState overlay,
  required ProviderContainer container,
  required FinanceRepository repo,
  required FinanceCategory category,
}) async {
  return softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(category.name, fallback: 'category'),
    delete: () async {
      await repo.softDeleteCategory(category.id);
      container.invalidate(financeCategoriesProvider);
    },
    restore: () async {
      // Categories are a handful of rows, so the tombstone is found by
      // sweeping the including-deleted list, as for a budget.
      final current = await repo
          .listCategories(includeDeleted: true)
          .then((all) => all.where((c) => c.id == category.id).firstOrNull);
      abortIfAlreadyRestored(
        found: current != null,
        deletedAt: current?.deletedAt,
      );
      // A tag another category took while this one was deleted stays there:
      // a tag can be in one category only (BUG-118).
      final others = [
        for (final c in await repo.listCategories())
          if (c.id != category.id) c,
      ];
      await repo.upsertCategory(
        FinanceCategory(
          id: category.id,
          createdAt: category.createdAt,
          updatedAt: utcNow(),
          version: restoreVersionFrom(
            preDeleteVersion: category.version,
            currentVersion: current?.version,
          ),
          name: category.name,
          colorValue: category.colorValue,
          tags: [
            for (final tag in category.tags)
              if (categoryForTags([tag], others) == null) tag,
          ],
        ),
      );
      container.invalidate(financeCategoriesProvider);
    },
  );
}

/// Soft-deletes [budget] and offers an undo. See [deleteSubscriptionWithUndo]
/// for why the overlay and container are passed in rather than looked up.
Future<bool> deleteBudgetWithUndo({
  required OverlayState overlay,
  required ProviderContainer container,
  required FinanceRepository repo,
  required Budget budget,
}) async {
  return softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(budget.tag, fallback: 'budget'),
    delete: () async {
      await repo.softDeleteBudget(budget.id);
      container.invalidate(budgetsProvider);
    },
    restore: () async {
      // No getBudget(id) on the repository, so the tombstone is found by
      // sweeping the including-deleted list — budgets are a handful of rows.
      final current = await repo
          .listBudgets(includeDeleted: true)
          .then(
            (all) => all.cast<Budget?>().firstWhere(
              (b) => b!.id == budget.id,
              orElse: () => null,
            ),
          );
      abortIfAlreadyRestored(
        found: current != null,
        deletedAt: current?.deletedAt,
      );
      await repo.upsertBudget(
        Budget(
          id: budget.id,
          createdAt: budget.createdAt,
          updatedAt: utcNow(),
          version: restoreVersionFrom(
            preDeleteVersion: budget.version,
            currentVersion: current?.version,
          ),
          tag: budget.tag,
          limitCents: budget.limitCents,
        ),
      );
      container.invalidate(budgetsProvider);
    },
  );
}

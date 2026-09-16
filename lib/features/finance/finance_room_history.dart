import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/finance/finance_room_event_modal.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart'
    show kIncomeGreen;

/// How a room event reads in a list: "Contribution", "Transfer to TFSA 2".
String roomEventTitle(AssetRoomEvent event, List<Asset> assets) {
  String counterName() =>
      assets.where((a) => a.id == event.counterAssetId).firstOrNull?.name ??
      'another asset';
  return switch (event.kind) {
    RoomEventKind.contribution => 'Contribution',
    RoomEventKind.withdrawal => 'Withdrawal',
    RoomEventKind.transferOut => 'Transfer to ${counterName()}',
    RoomEventKind.transferIn => 'Transfer from ${counterName()}',
  };
}

/// Soft-deletes [event] — with its ledger row and any other transfer leg —
/// and offers an undo. [overlay] and [container] are resolved by the caller
/// before the row that asked goes away.
Future<bool> deleteRoomEventWithUndo({
  required OverlayState overlay,
  required ProviderContainer container,
  required FinanceRepository repo,
  required AssetRoomEvent event,
  required String title,
}) {
  void refresh() {
    container.invalidate(assetRoomEventsProvider);
    container.invalidate(transactionsProvider);
  }

  return softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(title, fallback: 'entry'),
    delete: () async {
      await repo.softDeleteAssetRoomEvent(event.id);
      refresh();
    },
    restore: () async {
      final current = await repo.getAssetRoomEvent(event.id);
      abortIfAlreadyRestored(
        found: current != null,
        deletedAt: current?.deletedAt,
      );
      await repo.restoreAssetRoomEvent(event.id);
      refresh();
    },
  );
}

/// This year's (and any later, post-dated) contributions, withdrawals and
/// transfers on [asset], newest first. Tap one to edit it.
class RoomEventHistory extends ConsumerWidget {
  const RoomEventHistory({
    super.key,
    required this.asset,
    required this.container,
  });

  final Asset asset;

  /// The app-level container. The undo toast can outlive the sheet this list
  /// sits in, and the sheet's own scope is disposed with it.
  final ProviderContainer container;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final allEvents = ref.watch(assetRoomEventsProvider).valueOrNull ?? const [];
    final assets = ref.watch(assetsProvider).valueOrNull ?? const [];
    final events = [
      for (final e in allEvents)
        if (e.assetId == asset.id && e.occurredAt.year >= now.year) e,
    ];

    if (events.isEmpty) {
      return Text(
        'Nothing contributed, withdrawn or transferred this year.',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final event in events)
          _RoomEventRow(
            event: event,
            asset: asset,
            title: roomEventTitle(event, assets),
            legs: event.transferGroupId == null
                ? const []
                : [
                    for (final e in allEvents)
                      if (e.transferGroupId == event.transferGroupId) e,
                  ],
            assets: assets,
            container: container,
          ),
      ],
    );
  }
}

class _RoomEventRow extends ConsumerWidget {
  const _RoomEventRow({
    required this.event,
    required this.asset,
    required this.title,
    required this.legs,
    required this.assets,
    required this.container,
  });

  final ProviderContainer container;
  final AssetRoomEvent event;
  final Asset asset;
  final String title;

  /// Both legs of a transfer; empty otherwise.
  final List<AssetRoomEvent> legs;
  final List<Asset> assets;

  void _edit(BuildContext context, WidgetRef ref) {
    if (!event.kind.isTransfer) {
      showRoomCashEventModal(
        context,
        ref,
        asset: asset,
        kind: event.kind,
        existing: event,
      );
      return;
    }
    final outLeg = legs
        .where((l) => l.kind == RoomEventKind.transferOut)
        .firstOrNull;
    final from = assets.where((a) => a.id == outLeg?.assetId).firstOrNull;
    if (from == null) return;
    showRoomTransferModal(context, ref, from: from, existingLegs: legs);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final incoming =
        event.kind == RoomEventKind.contribution ||
        event.kind == RoomEventKind.transferIn;
    final color = incoming ? kIncomeGreen : theme.colorScheme.primary;
    final upcoming = !isRoomEventSettled(event, DateTime.now());
    final subtitle = [
      DateFormat('MMM d, yyyy').format(event.occurredAt),
      if (upcoming) 'Upcoming',
      if (event.note != null) event.note!,
    ].join(' · ');

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _edit(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              incoming
                  ? PhosphorIconsRegular.arrowDownLeft
                  : PhosphorIconsRegular.arrowUpRight,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              formatCents(
                incoming ? event.amountCents : -event.amountCents,
                signed: true,
              ),
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => deleteRoomEventWithUndo(
                overlay: Overlay.of(context, rootOverlay: true),
                container: container,
                repo: ref.read(financeRepositoryProvider),
                event: event,
                title: title,
              ),
              icon: Icon(
                PhosphorIconsRegular.trash,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: 'Delete',
              padding: EdgeInsets.zero,
              constraints: kMinTouchTarget,
            ),
          ],
        ),
      ),
    );
  }
}

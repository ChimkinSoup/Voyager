import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Records [valueCents] as [assetId]'s value on [day], replacing that day's
/// valuation if it has one — the same rule the asset sheet follows. Returns
/// the valuation's id.
Future<String> upsertValuationOnDay(
  FinanceRepository repo, {
  required String assetId,
  required DateTime day,
  required int valueCents,
}) async {
  final now = utcNow();
  final sameDay = (await repo.listAssetValuations(assetId: assetId))
      .where(
        (v) =>
            v.asOf.year == day.year &&
            v.asOf.month == day.month &&
            v.asOf.day == day.day,
      )
      .firstOrNull;
  final id = sameDay?.id ?? newId();
  await repo.upsertAssetValuation(
    AssetValuation(
      id: id,
      createdAt: sameDay?.createdAt ?? now,
      updatedAt: now,
      version: sameDay == null ? 0 : sameDay.version + 1,
      assetId: assetId,
      valueCents: valueCents,
      asOf: DateTime(day.year, day.month, day.day),
    ),
  );
  return id;
}

/// Writes a contribution or withdrawal on [asset]: the event, its ledger row,
/// and — when [valuationCents] is given — the asset's value on that day.
///
/// [eventId] and [transactionId] are minted once by the caller rather than
/// here, so a retry after a partial failure overwrites what the first attempt
/// wrote instead of filing the money twice. Editing passes [existing], whose
/// ids win.
Future<AssetRoomEvent> saveRoomCashEvent(
  FinanceRepository repo, {
  required Asset asset,
  required RoomEventKind kind,
  required int amountCents,
  required DateTime occurredAt,
  String? note,
  int? valuationCents,
  AssetRoomEvent? existing,
  required String eventId,
  required String transactionId,
}) async {
  assert(!kind.isTransfer, 'transfers go through saveRoomTransfer');
  final roomId = existing?.roomId ?? asset.contributionRoomId;
  if (roomId == null) {
    throw StateError('${asset.name} is not in a contribution room');
  }
  final now = utcNow();
  final id = existing?.id ?? eventId;
  final txId = existing?.transactionId ?? transactionId;

  final valuationId = valuationCents == null
      ? existing?.valuationId
      : await upsertValuationOnDay(
          repo,
          assetId: asset.id,
          day: occurredAt,
          valueCents: valuationCents,
        );

  // Versioned off disk, not off [existing]: a pull can land while the sheet
  // is open, and a write under its stale version would lose the next merge.
  final onDisk = await repo.getAssetRoomEvent(id);
  final event = AssetRoomEvent(
    id: id,
    createdAt: onDisk?.createdAt ?? now,
    updatedAt: now,
    version: onDisk == null ? 0 : onDisk.version + 1,
    assetId: asset.id,
    roomId: roomId,
    kind: kind,
    amountCents: amountCents,
    occurredAt: occurredAt,
    transactionId: txId,
    valuationId: valuationId,
    note: note,
  );
  await repo.upsertAssetRoomEvent(event);

  final tx = await repo.getTransaction(txId);
  await repo.upsertTransaction(
    FinancialTransaction(
      id: txId,
      createdAt: tx?.createdAt ?? now,
      updatedAt: now,
      version: tx == null ? 0 : tx.version + 1,
      type: kind == RoomEventKind.contribution
          ? TransactionType.deposit
          : TransactionType.expense,
      amountCents: amountCents,
      occurredAt: occurredAt,
      // A contribution's source is the account, so the ledger row reads as
      // "TFSA - note" without anyone typing it.
      origin: tx?.origin ?? asset.name,
      note: note,
      tags: tx?.tags ?? const [],
      roomEventId: id,
    ),
  );
  return event;
}

/// Writes a room-neutral move of [amountCents] from [from] to [to]: two legs
/// sharing a transfer group, no ledger rows, and each side's value on that day
/// when given.
///
/// Editing passes [existingLegs]; their ids and group are kept even if the
/// destination changed. New transfers pass ids minted once by the caller, for
/// the same retry reason as [saveRoomCashEvent].
Future<void> saveRoomTransfer(
  FinanceRepository repo, {
  required Asset from,
  required Asset to,
  required int amountCents,
  required DateTime occurredAt,
  String? note,
  int? fromValuationCents,
  int? toValuationCents,
  List<AssetRoomEvent> existingLegs = const [],
  required String transferGroupId,
  required String outLegId,
  required String inLegId,
}) async {
  final roomId = from.contributionRoomId;
  if (from.id == to.id || roomId == null || to.contributionRoomId != roomId) {
    throw ArgumentError('A transfer needs two assets in the same room');
  }
  final now = utcNow();
  final oldOut = existingLegs
      .where((l) => l.kind == RoomEventKind.transferOut)
      .firstOrNull;
  final oldIn = existingLegs
      .where((l) => l.kind == RoomEventKind.transferIn)
      .firstOrNull;
  final groupId = oldOut?.transferGroupId ?? transferGroupId;

  Future<void> writeLeg({
    required AssetRoomEvent? old,
    required String id,
    required RoomEventKind kind,
    required Asset asset,
    required Asset counter,
    required int? valuationCents,
  }) async {
    final valuationId = valuationCents == null
        ? old?.valuationId
        : await upsertValuationOnDay(
            repo,
            assetId: asset.id,
            day: occurredAt,
            valueCents: valuationCents,
          );
    final legId = old?.id ?? id;
    final onDisk = await repo.getAssetRoomEvent(legId);
    await repo.upsertAssetRoomEvent(
      AssetRoomEvent(
        id: legId,
        createdAt: onDisk?.createdAt ?? now,
        updatedAt: now,
        version: onDisk == null ? 0 : onDisk.version + 1,
        assetId: asset.id,
        roomId: roomId,
        kind: kind,
        amountCents: amountCents,
        occurredAt: occurredAt,
        valuationId: valuationId,
        counterAssetId: counter.id,
        transferGroupId: groupId,
        note: note,
      ),
    );
  }

  await writeLeg(
    old: oldOut,
    id: outLegId,
    kind: RoomEventKind.transferOut,
    asset: from,
    counter: to,
    valuationCents: fromValuationCents,
  );
  await writeLeg(
    old: oldIn,
    id: inLegId,
    kind: RoomEventKind.transferIn,
    asset: to,
    counter: from,
    valuationCents: toValuationCents,
  );
}

/// Carries an edit made to a linked ledger row over to its room event, so
/// the ledger and the room can't disagree about how much moved or when.
Future<void> syncRoomEventFromTransaction(
  FinanceRepository repo,
  FinancialTransaction transaction,
) async {
  final eventId = transaction.roomEventId;
  if (eventId == null) return;
  final event = await repo.getAssetRoomEvent(eventId);
  if (event == null || event.deletedAt != null) return;
  if (event.amountCents == transaction.amountCents &&
      event.occurredAt == transaction.occurredAt &&
      event.note == transaction.note) {
    return;
  }
  await repo.upsertAssetRoomEvent(
    event.copyWith(
      amountCents: transaction.amountCents,
      occurredAt: transaction.occurredAt,
      note: transaction.note,
      clearNote: transaction.note == null,
      updatedAt: utcNow(),
      version: event.version + 1,
    ),
  );
}

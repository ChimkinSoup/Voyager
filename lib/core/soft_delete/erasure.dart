import 'package:voyager/core/sync/firestore_document_mapper.dart';

/// The `deletedAt` an erased row carries: a tombstone emptied by "Delete
/// forever" in the trash (`TRASH_HLD.md` §6.4).
///
/// Earlier than any purge cutoff, so the trash — which lists only rows deleted
/// inside the retention window — stops showing it on every device the moment
/// the erase arrives there. The purge never drops an erased row (see
/// [SoftDeletePolicy.isExpired]): the emptied row is what rejects a stale copy
/// of the item coming back from another device, however long that device was
/// offline.
final kErasedAt = DateTime.utc(1970);

/// How far an erase advances a row's version.
///
/// An erase is final — nothing can restore or edit the row afterwards — so it
/// has to outrank a concurrent edit made on another device, even one that sat
/// offline through a long run of version-bumping saves. `+ 1` would lose to any
/// such edit and bring the item back.
const kEraseVersionStep = 1 << 20;

bool isErasedAt(DateTime? deletedAt) =>
    deletedAt != null && deletedAt.isAtSameMomentAs(kErasedAt);

/// [isErasedAt] for a record in its Firestore payload shape.
bool isErasedPayload(Map<String, dynamic> data) =>
    isErasedAt(parseFirestoreDate(data['deletedAt']));

/// Why a document was quarantined rather than merged.
///
/// Lives here rather than beside the detector because it is persisted with the
/// conflict and read back by the resolution UI, so the storage layer and the
/// presentation layer both need it without either depending on `core/sync`.
enum SyncConflictReason {
  /// The remote operation log could not be replayed into determinate text.
  corruptedOpChain('corrupted_op_chain'),

  /// Two devices claim the same version and edit timestamp for a document but
  /// disagree about its metadata, so neither one is the later write.
  hardMetadataCollision('hard_metadata_collision');

  const SyncConflictReason(this.storageValue);

  /// Stable string written to the database. Never derive this from [name] —
  /// renaming a value would orphan every conflict already on disk.
  final String storageValue;

  static SyncConflictReason? fromStorage(String? value) {
    if (value == null) return null;
    for (final reason in SyncConflictReason.values) {
      if (reason.storageValue == value) return reason;
    }
    // A reason written by a newer build than this one. The conflict itself is
    // still resolvable, so surface it without the label rather than throwing.
    return null;
  }
}

class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.collection,
    required this.documentId,
    required this.localPayloadJson,
    required this.remotePayloadJson,
    required this.detectedAt,
    this.reason,
    this.localTitle,
    this.remoteTitle,
    this.localText,
    this.remoteText,
  });

  final String id;
  final String collection;
  final String documentId;
  final String localPayloadJson;
  final String remotePayloadJson;
  final DateTime detectedAt;

  /// Null for conflicts quarantined before this was recorded.
  final SyncConflictReason? reason;

  final String? localTitle;
  final String? remoteTitle;
  final String? localText;
  final String? remoteText;
}

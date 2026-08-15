import 'package:firebase_core/firebase_core.dart';
import 'package:voyager/domain/services/character_operation.dart';

/// Whether a failed sync write is worth attempting again.
enum SyncFailureKind {
  /// Something about the environment failed — connectivity, a timeout, backend
  /// contention. The identical write may well succeed later.
  transient,

  /// The write itself is unacceptable and will be rejected identically every
  /// time. Retrying wastes attempts and, if it is queued, blocks whatever is
  /// queued behind it.
  permanent,
}

/// Firestore error codes that describe the request rather than the conditions
/// around it. Everything else — `unavailable`, `deadline-exceeded`, `aborted`,
/// `internal`, `resource-exhausted`, `cancelled`, `unknown` — is worth a retry.
const _permanentFirestoreCodes = {
  'invalid-argument',
  'permission-denied',
  'unauthenticated',
  'not-found',
  'already-exists',
  'failed-precondition',
  'out-of-range',
  'unimplemented',
  'data-loss',
};

/// Classifies [error] from a sync write.
///
/// Unrecognised errors are treated as [SyncFailureKind.transient] on purpose:
/// the cost of a wrong "transient" is a retry, while the cost of a wrong
/// "permanent" is discarding a document the user still expects to be synced.
/// Callers must therefore cap how long they keep retrying rather than relying
/// on this to eventually say stop.
SyncFailureKind classifySyncFailure(Object error) {
  if (error is SyncPayloadTooLargeException) return SyncFailureKind.permanent;
  if (error is FirebaseException) {
    return _permanentFirestoreCodes.contains(error.code)
        ? SyncFailureKind.permanent
        : SyncFailureKind.transient;
  }
  return SyncFailureKind.transient;
}

/// Short, user-facing reason recorded against a parked upload.
String describeSyncFailure(Object error) {
  if (error is SyncPayloadTooLargeException) {
    return 'Too large to sync: ${error.part} is ${error.bytes} bytes, over '
        'the ${error.maxBytes} byte limit.';
  }
  if (error is FirebaseException) {
    return '[${error.code}] ${error.message ?? 'Firestore rejected the write.'}';
  }
  return error.toString();
}

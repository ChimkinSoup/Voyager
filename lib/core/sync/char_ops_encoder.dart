import 'package:flutter/foundation.dart';
import 'package:voyager/domain/services/character_operation.dart';

/// Op count from which chunking and encoding a write is handed to a background
/// isolate instead of run inline.
///
/// [CharOpsPayload.intoChunks] encodes every operation once to measure it and
/// then [CharOpsPayload.encode] encodes the whole envelope again, so the cost
/// is linear in the op count with a large constant. Under this threshold that
/// is cheaper than the isolate hop; over it, the inline version is long enough
/// to eat a frame — and the two cases that go far over (a full-document reseed,
/// which emits one op per character, and operation-log compaction, which does
/// not even start until a document has 200 operations) are exactly the ones
/// that used to fire while the user was typing or opening an entry.
const int charOpEncodeIsolateThreshold = 256;

/// Chunks and encodes one logical write, off the UI isolate when it is big
/// enough to be worth it.
///
/// Returns one encoded envelope per chunk, in order, ready to become a
/// `SyncOperation.payload`; the list length is the chunk count. Throws
/// [SyncPayloadTooLargeException] the same way [CharOpsPayload.intoChunks]
/// does, from either path.
Future<List<String>> encodeCharOpPayloads({
  required List<CharacterOperation> charOps,
  required Map<String, dynamic>? snapshot,
  required String groupId,
  required int maxPayloadBytes,
}) {
  final request = CharOpsEncodeRequest(
    charOps: charOps,
    snapshot: snapshot,
    groupId: groupId,
    maxPayloadBytes: maxPayloadBytes,
  );
  if (charOps.length < charOpEncodeIsolateThreshold) {
    return Future.value(encodeCharOpPayloadsSync(request));
  }
  return compute(encodeCharOpPayloadsSync, request);
}

/// The inputs [encodeCharOpPayloads] hands to the background isolate.
///
/// Every field is a plain value or a plain Dart object, which is what lets the
/// whole request be copied across. In particular [snapshot] must stay a
/// JSON-shaped map of primitives — the Firestore document mappers already
/// guarantee that, since the same map is `jsonEncode`d on the way out.
@immutable
class CharOpsEncodeRequest {
  const CharOpsEncodeRequest({
    required this.charOps,
    required this.snapshot,
    required this.groupId,
    required this.maxPayloadBytes,
  });

  final List<CharacterOperation> charOps;
  final Map<String, dynamic>? snapshot;
  final String groupId;
  final int maxPayloadBytes;
}

/// The encode itself, as a top-level function so it can be the entry point of
/// a background isolate. Also the inline path below the threshold.
@visibleForTesting
List<String> encodeCharOpPayloadsSync(CharOpsEncodeRequest request) {
  final chunks = CharOpsPayload.intoChunks(
    charOps: request.charOps,
    snapshot: request.snapshot,
    groupId: request.groupId,
    maxPayloadBytes: request.maxPayloadBytes,
  );
  return [for (final chunk in chunks) chunk.encode()];
}

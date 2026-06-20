import 'dart:convert';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/sequence_crdt_merger.dart';

/// Resolves a document snapshot from merged CRDT [SyncOperation]s.
///
/// Push and pull both use this resolver so the merged payload is the
/// single source of truth when operations exist.
class CrdtDocumentResolver {
  CrdtDocumentResolver({SequenceCrdtMerger? merger})
    : _merger = merger ?? SequenceCrdtMerger();

  final SequenceCrdtMerger _merger;

  Future<Map<String, dynamic>?> resolvePayload(
    SyncRepository repository,
    String documentId, {
    List<SyncOperation> localOperations = const [],
  }) async {
    final remoteOperations = await repository.listOperations(documentId);
    if (remoteOperations.isEmpty && localOperations.isEmpty) {
      return null;
    }

    final merged = _merger.merge(localOperations, remoteOperations);
    final payloadJson = _merger.applyMergedPayload(merged);
    if (payloadJson.isEmpty) return null;

    return jsonDecode(payloadJson) as Map<String, dynamic>;
  }
}

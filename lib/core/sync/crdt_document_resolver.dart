import 'dart:convert';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

/// Resolves a document snapshot from merged CRDT [SyncOperation]s.
///
/// Push and pull both use this resolver so the merged payload is the
/// single source of truth when operations exist.
class CrdtDocumentResolver {
  CrdtDocumentResolver({CharacterSequenceCrdtMerger? merger})
    : _merger = merger ?? CharacterSequenceCrdtMerger();

  final CharacterSequenceCrdtMerger _merger;

  Future<Map<String, dynamic>?> resolvePayload(
    SyncRepository repository,
    String documentId, {
    List<SyncOperation> localOperations = const [],
  }) async {
    final remoteOperations = await repository.listOperations(documentId);
    if (remoteOperations.isEmpty && localOperations.isEmpty) {
      return null;
    }

    final merged = _mergeSyncOperations(localOperations, remoteOperations);
    final payloadJson = _merger.applyMergedPayload(merged);
    if (payloadJson.isEmpty) return null;

    return jsonDecode(payloadJson) as Map<String, dynamic>;
  }

  List<SyncOperation> _mergeSyncOperations(
    List<SyncOperation> local,
    List<SyncOperation> remote,
  ) {
    final all = [...local, ...remote];
    all.sort((a, b) {
      final seq = a.sequence.compareTo(b.sequence);
      if (seq != 0) return seq;
      return a.timestamp.compareTo(b.timestamp);
    });

    final seen = <String>{};
    return all.where((op) => seen.add(op.id)).toList();
  }
}

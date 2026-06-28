import 'dart:convert';

import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

enum SyncConflictReason {
  corruptedOpChain,
  hardMetadataCollision,
}

class SyncConflictDetection {
  const SyncConflictDetection({
    required this.isConflict,
    this.reason,
    this.remotePayload,
  });

  final bool isConflict;
  final SyncConflictReason? reason;
  final Map<String, dynamic>? remotePayload;
}

class SyncConflictDetector {
  SyncConflictDetector({CharacterSequenceCrdtMerger? merger})
    : _merger = merger ?? CharacterSequenceCrdtMerger();

  final CharacterSequenceCrdtMerger _merger;

  SyncConflictDetection detectJournalEntryConflict({
    required JournalEntry? local,
    required Map<String, dynamic> remoteData,
    required List<CharacterOperation> remoteCharOps,
    bool forceConflict = false,
  }) {
    if (forceConflict) {
      return SyncConflictDetection(
        isConflict: true,
        reason: SyncConflictReason.corruptedOpChain,
        remotePayload: remoteData,
      );
    }

    if (_isCorruptedOpChain(remoteCharOps)) {
      return SyncConflictDetection(
        isConflict: true,
        reason: SyncConflictReason.corruptedOpChain,
        remotePayload: remoteData,
      );
    }

    if (local != null && _isHardMetadataCollision(local, remoteData)) {
      return SyncConflictDetection(
        isConflict: true,
        reason: SyncConflictReason.hardMetadataCollision,
        remotePayload: remoteData,
      );
    }

    return const SyncConflictDetection(isConflict: false);
  }

  SyncConflictDetection detectTodoTaskConflict({
    required TodoTask? local,
    required Map<String, dynamic> remoteData,
    required List<CharacterOperation> remoteCharOps,
    bool forceConflict = false,
  }) {
    if (forceConflict) {
      return SyncConflictDetection(
        isConflict: true,
        reason: SyncConflictReason.corruptedOpChain,
        remotePayload: remoteData,
      );
    }

    if (_isCorruptedOpChain(remoteCharOps)) {
      return SyncConflictDetection(
        isConflict: true,
        reason: SyncConflictReason.corruptedOpChain,
        remotePayload: remoteData,
      );
    }

    if (local != null && _isHardTodoMetadataCollision(local, remoteData)) {
      return SyncConflictDetection(
        isConflict: true,
        reason: SyncConflictReason.hardMetadataCollision,
        remotePayload: remoteData,
      );
    }

    return const SyncConflictDetection(isConflict: false);
  }

  bool _isCorruptedOpChain(List<CharacterOperation> ops) {
    try {
      _merger.validateOpChain(ops);
      return false;
    } catch (_) {
      return true;
    }
  }

  bool _isHardMetadataCollision(JournalEntry local, Map<String, dynamic> remote) {
    final remoteVersion = parseVersion(remote);
    final remoteUpdated = parseFirestoreDate(remote['updatedAt']);
    if (local.version != remoteVersion) return false;
    if (remoteUpdated == null || !local.updatedAt.isAtSameMomentAs(remoteUpdated)) {
      return false;
    }
    final remoteTitle = remote['title'] as String? ?? '';
    final remoteJournalId = journalReferenceIdFromFirestore(
      remote['journalId'] as String? ?? local.journalId,
    );
    return local.title != remoteTitle ||
        local.journalId != remoteJournalId ||
        local.mood != remote['mood'] ||
        local.weatherIcon != remote['weatherIcon'];
  }

  bool _isHardTodoMetadataCollision(TodoTask local, Map<String, dynamic> remote) {
    final remoteVersion = parseVersion(remote);
    final remoteUpdated = parseFirestoreDate(remote['updatedAt']);
    if (local.version != remoteVersion) return false;
    if (remoteUpdated == null || !local.updatedAt.isAtSameMomentAs(remoteUpdated)) {
      return false;
    }
    return local.title != (remote['title'] as String? ?? local.title) ||
        local.listId !=
            todoListDocumentIdFromFirestore(
              remote['listId'] as String? ?? local.listId,
            );
  }

  static String payloadJson(Map<String, dynamic> data) => jsonEncode(data);
}

import 'dart:convert';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_operation.dart';

/// Character-level CRDT merge engine using fractional indexing.
class CharacterSequenceCrdtMerger {
  /// Collects and merges explicit [CharOpsPayload] character operations only.
  ///
  /// Legacy full-document snapshot operations are never expanded into synthetic
  /// character ops — that duplicated fractional positions across saves and
  /// produced garbled interleaved text.
  List<CharacterOperation> mergeOperations(
    List<SyncOperation> local,
    List<SyncOperation> remote,
  ) {
    final byId = <String, CharacterOperation>{};
    for (final syncOp in [...local, ...remote]) {
      for (final op in _extractExplicitCharOps(syncOp.payload)) {
        final existing = byId[op.id];
        if (existing == null || _wins(op, existing)) {
          byId[op.id] = op;
        }
      }
    }
    return byId.values.toList();
  }

  /// Reconstructs merged plain text from character operations.
  String applyMergedText(List<CharacterOperation> merged) {
    final live = merged.where((op) => !op.deleted).toList()
      ..sort((a, b) {
        final pos = a.position.compareTo(b.position);
        if (pos != 0) return pos;
        final clock = a.logicalClock.compareTo(b.logicalClock);
        if (clock != 0) return clock;
        return a.clientId.compareTo(b.clientId);
      });
    return live.map((op) => op.character).join();
  }

  /// Returns merged document JSON from operations, or empty if none.
  String applyMergedPayload(List<SyncOperation> merged) {
    if (merged.isEmpty) return '';

    final latestSnapshot = _latestSnapshot(merged);
    final charOps = mergeOperations(const [], merged);

    if (charOps.isNotEmpty && latestSnapshot != null) {
      final snapshotBody = _textFromSnapshot(latestSnapshot);
      final mergedBody = applyMergedText(charOps);
      final body = _pickBody(
        mergedBody: mergedBody,
        snapshotBody: snapshotBody,
      );
      final result = Map<String, dynamic>.from(latestSnapshot)
        ..['body'] = body;
      if (latestSnapshot.containsKey('notes')) {
        result['notes'] = body.isEmpty ? null : body;
      }
      return jsonEncode(result);
    }

    if (charOps.isNotEmpty) {
      return jsonEncode({
        'body': applyMergedText(charOps),
        'notes': applyMergedText(charOps),
      });
    }

    if (latestSnapshot != null) {
      return jsonEncode(latestSnapshot);
    }

    // Raw legacy payloads with no parseable document shape.
    merged.sort((a, b) {
      final seq = a.sequence.compareTo(b.sequence);
      if (seq != 0) return seq;
      return a.timestamp.compareTo(b.timestamp);
    });
    return merged.last.payload;
  }

  /// Throws if the op chain cannot produce stable text.
  void validateOpChain(List<CharacterOperation> ops) {
    applyMergedText(ops);
    final positions = ops.where((op) => !op.deleted).map((op) => op.position);
    final seen = <String>{};
    for (final pos in positions) {
      if (!seen.add(pos)) {
        throw FormatException('Duplicate fractional position: $pos');
      }
    }
  }

  bool _wins(CharacterOperation incoming, CharacterOperation existing) {
    if (incoming.deleted != existing.deleted) {
      return incoming.logicalClock >= existing.logicalClock;
    }
    if (incoming.logicalClock != existing.logicalClock) {
      return incoming.logicalClock > existing.logicalClock;
    }
    return incoming.clientId.compareTo(existing.clientId) > 0;
  }

  List<CharacterOperation> _extractExplicitCharOps(String payload) {
    return CharOpsPayload.tryParse(payload)?.charOps ?? const [];
  }

  Map<String, dynamic>? _latestSnapshot(List<SyncOperation> merged) {
    Map<String, dynamic>? latestSnapshot;
    DateTime? latestSnapshotTime;

    for (final syncOp in merged) {
      final snap = _extractSnapshot(syncOp.payload);
      if (snap != null &&
          (latestSnapshotTime == null ||
              !syncOp.timestamp.isBefore(latestSnapshotTime!))) {
        latestSnapshot = snap;
        latestSnapshotTime = syncOp.timestamp;
      }
    }
    return latestSnapshot;
  }

  Map<String, dynamic>? _extractSnapshot(String payload) {
    final parsed = CharOpsPayload.tryParse(payload);
    if (parsed?.snapshot != null) return parsed!.snapshot;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic> &&
          (decoded.containsKey('body') ||
              decoded.containsKey('title') ||
              decoded.containsKey('notes'))) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  String _textFromSnapshot(Map<String, dynamic> snapshot) {
    return snapshot['body'] as String? ?? snapshot['notes'] as String? ?? '';
  }

  String _pickBody({
    required String mergedBody,
    required String snapshotBody,
  }) {
    if (mergedBody.isEmpty) return snapshotBody;
    if (snapshotBody.isEmpty) return mergedBody;
    // Guard against corrupted merges that interleave duplicate characters.
    if (mergedBody.length > snapshotBody.length * 2 &&
        mergedBody.length > snapshotBody.length + 32) {
      return snapshotBody;
    }
    return mergedBody;
  }
}

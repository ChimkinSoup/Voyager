import 'dart:convert';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_operation.dart';

/// A parsed char-op envelope kept alongside the timestamp of the operation
/// document it came from, so snapshot recency survives parsing.
class _ParsedPayload {
  const _ParsedPayload(this.payload, this.timestamp);

  final CharOpsPayload payload;
  final DateTime timestamp;
}

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
    return _mergeParsed(_completeCharOpPayloads([...local, ...remote]));
  }

  List<CharacterOperation> _mergeParsed(List<_ParsedPayload> parsed) {
    final byId = <String, CharacterOperation>{};
    for (final entry in parsed) {
      for (final op in entry.payload.charOps) {
        final existing = byId[op.id];
        if (existing == null || _wins(op, existing)) {
          byId[op.id] = op;
        }
      }
    }
    return byId.values.toList();
  }

  /// Parses every char-op envelope in [ops], dropping those that belong to a
  /// chunk group with chunks missing.
  ///
  /// A write split across several documents can be interrupted partway. The
  /// surviving chunks would otherwise reconstruct a body missing whatever the
  /// absent chunks carried — and [_pickBody] only rejects merges that come out
  /// *longer* than the snapshot, so a short one would be adopted as real text.
  /// Ignoring the group until it is whole leaves the previous complete state
  /// in place instead.
  List<_ParsedPayload> _completeCharOpPayloads(List<SyncOperation> ops) {
    final parsed = <_ParsedPayload>[];
    final seenIndexes = <String, Set<int>>{};
    final expectedCounts = <String, int>{};

    for (final syncOp in ops) {
      final payload = CharOpsPayload.tryParse(syncOp.payload);
      if (payload == null) continue;
      parsed.add(_ParsedPayload(payload, syncOp.timestamp));

      final groupId = payload.groupId;
      if (groupId == null || payload.chunkCount <= 1) continue;
      (seenIndexes[groupId] ??= <int>{}).add(payload.chunkIndex);
      expectedCounts[groupId] = payload.chunkCount;
    }

    return parsed.where((entry) {
      final groupId = entry.payload.groupId;
      if (groupId == null || entry.payload.chunkCount <= 1) return true;
      return seenIndexes[groupId]!.length == expectedCounts[groupId];
    }).toList();
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

    final complete = _completeCharOpPayloads(merged);
    final latestSnapshot = _latestSnapshot(merged, complete);
    final charOps = _mergeParsed(complete);

    if (charOps.isNotEmpty && latestSnapshot != null) {
      final snapshotBody = _textFromSnapshot(latestSnapshot);
      final mergedBody = applyMergedText(charOps);
      final body = _pickBody(
        mergedBody: mergedBody,
        snapshotBody: snapshotBody,
      );
      final result = Map<String, dynamic>.from(latestSnapshot)..['body'] = body;
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
  ///
  /// Two live operations sharing a fractional position is not corruption:
  /// [applyMergedText] breaks that tie on logical clock and then client id, so
  /// the text they resolve to is fully determined. Only operations that tie on
  /// all three are genuinely ambiguous. Rejecting bare position duplicates
  /// quarantined documents whose chain resolved perfectly — three collisions
  /// among a thousand live characters was enough — and because resolving a
  /// conflict never removed the colliding operations, the next pull raised the
  /// same conflict again, forever.
  ///
  /// A chain that really is doubled (every character present twice, from a
  /// reseed that never tombstoned the original ops) still gets caught, by
  /// [_pickBody] rejecting a merge that comes out far longer than the snapshot.
  void validateOpChain(List<CharacterOperation> ops) {
    applyMergedText(ops);
    final seen = <String>{};
    for (final op in ops.where((op) => !op.deleted)) {
      final orderingKey = '${op.position}|${op.logicalClock}|${op.clientId}';
      if (!seen.add(orderingKey)) {
        throw FormatException(
          'Ambiguous operation ordering at position ${op.position}',
        );
      }
    }
  }

  bool _wins(CharacterOperation incoming, CharacterOperation existing) {
    if (incoming.deleted != existing.deleted) {
      return incoming.deleted;
    }
    if (incoming.logicalClock != existing.logicalClock) {
      return incoming.logicalClock > existing.logicalClock;
    }
    return incoming.clientId.compareTo(existing.clientId) > 0;
  }

  /// Newest snapshot across char-op envelopes from complete groups and legacy
  /// bare-JSON payloads alike. A snapshot from an incomplete chunk group is
  /// skipped along with that group's character ops — it describes a write that
  /// only partly landed.
  Map<String, dynamic>? _latestSnapshot(
    List<SyncOperation> merged,
    List<_ParsedPayload> complete,
  ) {
    Map<String, dynamic>? latestSnapshot;
    DateTime? latestSnapshotTime;

    void consider(Map<String, dynamic>? snapshot, DateTime timestamp) {
      if (snapshot == null) return;
      if (latestSnapshotTime == null ||
          !timestamp.isBefore(latestSnapshotTime!)) {
        latestSnapshot = snapshot;
        latestSnapshotTime = timestamp;
      }
    }

    for (final entry in complete) {
      consider(entry.payload.snapshot, entry.timestamp);
    }
    for (final syncOp in merged) {
      if (CharOpsPayload.tryParse(syncOp.payload) != null) continue;
      consider(_legacySnapshot(syncOp.payload), syncOp.timestamp);
    }
    return latestSnapshot;
  }

  /// A whole-document payload written before the char-op envelope existed.
  Map<String, dynamic>? _legacySnapshot(String payload) {
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

  String _pickBody({required String mergedBody, required String snapshotBody}) {
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

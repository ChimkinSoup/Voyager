import 'dart:convert';

/// A single character-level CRDT operation.
class CharacterOperation {
  const CharacterOperation({
    required this.id,
    required this.clientId,
    required this.logicalClock,
    required this.position,
    required this.character,
    this.deleted = false,
  });

  final String id;
  final String clientId;
  final int logicalClock;
  final String position;
  final String character;
  final bool deleted;

  CharacterOperation copyWith({
    bool? deleted,
    String? character,
  }) {
    return CharacterOperation(
      id: id,
      clientId: clientId,
      logicalClock: logicalClock,
      position: position,
      character: character ?? this.character,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'clientId': clientId,
    'logicalClock': logicalClock,
    'position': position,
    'character': character,
    'deleted': deleted,
  };

  factory CharacterOperation.fromJson(Map<String, dynamic> json) {
    return CharacterOperation(
      id: json['id'] as String,
      clientId: json['clientId'] as String,
      logicalClock: (json['logicalClock'] as num).toInt(),
      position: json['position'] as String,
      character: json['character'] as String? ?? '',
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  static List<CharacterOperation> listFromJsonString(String jsonString) {
    final decoded = jsonDecode(jsonString);
    if (decoded is! List) return const [];
    return decoded
        .cast<Map<String, dynamic>>()
        .map(CharacterOperation.fromJson)
        .toList();
  }

  static String listToJsonString(List<CharacterOperation> ops) {
    return jsonEncode(ops.map((op) => op.toJson()).toList());
  }
}

/// Thrown when a payload can't be made to fit the per-property size limit by
/// splitting it, because a single indivisible part is already over budget.
///
/// This is a permanent failure — retrying the identical write can never
/// succeed — so it is classified as such by `classifySyncFailure`.
class SyncPayloadTooLargeException implements Exception {
  const SyncPayloadTooLargeException({
    required this.part,
    required this.bytes,
    required this.maxBytes,
  });

  /// Which indivisible piece was oversized, for the failure message.
  final String part;
  final int bytes;
  final int maxBytes;

  @override
  String toString() =>
      'SyncPayloadTooLargeException: $part is $bytes bytes, over the '
      '$maxBytes byte limit';
}

/// Payload envelope stored in [SyncOperation.payload].
///
/// One logical write may be split across several envelopes when its character
/// operations don't fit a single document — see [intoChunks]. Every envelope
/// in such a split shares a [groupId] and carries the total [chunkCount], so a
/// reader can tell a complete group from a partially-written one. Envelopes
/// written as a single document omit all three fields and parse back as a
/// complete one-chunk group, which keeps this format compatible with payloads
/// written before chunking existed.
class CharOpsPayload {
  const CharOpsPayload({
    required this.charOps,
    this.snapshot,
    this.groupId,
    this.chunkIndex = 0,
    this.chunkCount = 1,
  });

  static const formatKey = 'format';
  static const charOpsKey = 'charOps';
  static const formatValue = 'char_ops';
  static const groupIdKey = 'groupId';
  static const chunkIndexKey = 'chunkIndex';
  static const chunkCountKey = 'chunkCount';

  /// Bytes of envelope scaffolding (keys, braces, group metadata) to hold back
  /// from the per-chunk budget. Generous on purpose — overshooting the real
  /// limit costs one extra chunk, undershooting costs a rejected write.
  static const _envelopeOverheadBytes = 256;

  final List<CharacterOperation> charOps;
  final Map<String, dynamic>? snapshot;

  /// Shared across every chunk of one logical write; null when unsplit.
  final String? groupId;
  final int chunkIndex;
  final int chunkCount;

  Map<String, dynamic> toJson() => {
    formatKey: formatValue,
    charOpsKey: charOps.map((op) => op.toJson()).toList(),
    if (snapshot != null) 'snapshot': snapshot,
    if (chunkCount > 1) ...{
      groupIdKey: groupId,
      chunkIndexKey: chunkIndex,
      chunkCountKey: chunkCount,
    },
  };

  String encode() => jsonEncode(toJson());

  /// Splits [charOps] into as few envelopes as will each stay under
  /// [maxPayloadBytes] once encoded.
  ///
  /// [snapshot] rides along in the first chunk only — replicating it per chunk
  /// would multiply the write by the chunk count for no benefit, since readers
  /// only ever use the latest one.
  ///
  /// Throws [SyncPayloadTooLargeException] if the snapshot alone doesn't fit.
  /// At that size the mirrored document write is over the limit too, so
  /// silently dropping the snapshot here would just move the failure somewhere
  /// harder to see.
  static List<CharOpsPayload> intoChunks({
    required List<CharacterOperation> charOps,
    required Map<String, dynamic>? snapshot,
    required String groupId,
    required int maxPayloadBytes,
  }) {
    final budget = maxPayloadBytes - _envelopeOverheadBytes;
    if (budget <= 0) {
      throw SyncPayloadTooLargeException(
        part: 'envelope overhead',
        bytes: _envelopeOverheadBytes,
        maxBytes: maxPayloadBytes,
      );
    }

    // `,"snapshot":` plus the encoded map.
    final snapshotBytes = snapshot == null
        ? 0
        : _utf8Bytes(jsonEncode(snapshot)) + 13;
    if (snapshotBytes >= budget) {
      throw SyncPayloadTooLargeException(
        part: 'document snapshot',
        bytes: snapshotBytes,
        maxBytes: budget,
      );
    }

    final groups = <List<CharacterOperation>>[];
    var current = <CharacterOperation>[];
    var used = snapshotBytes;

    for (final op in charOps) {
      // `+ 1` for the comma joining this op to the previous one.
      final size = _utf8Bytes(jsonEncode(op.toJson())) + 1;
      if (size >= budget) {
        throw SyncPayloadTooLargeException(
          part: 'character operation',
          bytes: size,
          maxBytes: budget,
        );
      }
      // `used > 0` rather than `current.isNotEmpty`: when the snapshot leaves
      // no room for even the first op, chunk 0 carries the snapshot alone and
      // the ops start at chunk 1.
      if (used > 0 && used + size > budget) {
        groups.add(current);
        current = <CharacterOperation>[];
        used = 0;
      }
      current.add(op);
      used += size;
    }
    groups.add(current);

    return [
      for (var i = 0; i < groups.length; i++)
        CharOpsPayload(
          charOps: groups[i],
          snapshot: i == 0 ? snapshot : null,
          groupId: groups.length > 1 ? groupId : null,
          chunkIndex: i,
          chunkCount: groups.length,
        ),
    ];
  }

  static int _utf8Bytes(String value) => utf8.encode(value).length;

  static CharOpsPayload? tryParse(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded[formatKey] != formatValue) return null;
      final rawOps = decoded[charOpsKey];
      if (rawOps is! List) return null;
      final ops = rawOps
          .cast<Map<String, dynamic>>()
          .map(CharacterOperation.fromJson)
          .toList();
      final snap = decoded['snapshot'];
      final rawCount = decoded[chunkCountKey];
      final rawIndex = decoded[chunkIndexKey];
      return CharOpsPayload(
        charOps: ops,
        snapshot: snap is Map<String, dynamic> ? snap : null,
        groupId: decoded[groupIdKey] as String?,
        chunkIndex: rawIndex is num ? rawIndex.toInt() : 0,
        chunkCount: rawCount is num ? rawCount.toInt() : 1,
      );
    } catch (_) {
      return null;
    }
  }
}

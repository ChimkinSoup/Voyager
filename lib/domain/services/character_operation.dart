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

/// Payload envelope stored in [SyncOperation.payload].
class CharOpsPayload {
  const CharOpsPayload({required this.charOps, this.snapshot});

  static const formatKey = 'format';
  static const charOpsKey = 'charOps';
  static const formatValue = 'char_ops';

  final List<CharacterOperation> charOps;
  final Map<String, dynamic>? snapshot;

  Map<String, dynamic> toJson() => {
    formatKey: formatValue,
    charOpsKey: charOps.map((op) => op.toJson()).toList(),
    if (snapshot != null) 'snapshot': snapshot,
  };

  String encode() => jsonEncode(toJson());

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
      return CharOpsPayload(
        charOps: ops,
        snapshot: snap is Map<String, dynamic> ? snap : null,
      );
    } catch (_) {
      return null;
    }
  }
}

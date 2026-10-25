/// Gaia's chats, messages and settings (GAIA_HLD.md §8): stored in drift by
/// the main instance, synced like any other collection, and carried over the
/// pipe to the companion as JSON.
library;

import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

enum GaiaMessageRole { user, assistant }

enum GaiaMessageStatus {
  streaming,
  complete,
  error,
  cancelled,
  interrupted,
  aborted,
}

/// The only adapter until Phase 2.
const kGaiaClaudeCodeAdapter = 'claude_code';

/// The key a chat's native session on [deviceId] is kept under. A session
/// lives on the machine that ran it, so each device has its own (§7.4).
String gaiaSessionKey(
  String deviceId, {
  String adapter = kGaiaClaudeCodeAdapter,
}) => '$deviceId/$adapter';

/// One native CLI session of a chat: its id, and the seq of the last message
/// it took part in.
class GaiaAgentSession {
  const GaiaAgentSession({required this.sessionId, required this.lastSeq});

  final String sessionId;
  final int lastSeq;

  Map<String, Object?> toJson() => {'sessionId': sessionId, 'lastSeq': lastSeq};

  factory GaiaAgentSession.fromJson(Map<String, Object?> json) =>
      GaiaAgentSession(
        sessionId: json['sessionId']! as String,
        lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
      );
}

class GaiaChat extends SoftDeletable {
  const GaiaChat({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.title,
    required this.lastMessageAt,
    this.pinned = false,
    this.agentSessions = const {},
  });

  final String title;
  final DateTime lastMessageAt;
  final bool pinned;

  /// Keyed by [gaiaSessionKey].
  final Map<String, GaiaAgentSession> agentSessions;

  /// The session this chat resumes on [deviceId], or null to start one.
  String? sessionOn(String deviceId) =>
      agentSessions[gaiaSessionKey(deviceId)]?.sessionId;

  /// [touch] off leaves [updatedAt] where it was; [bumpVersion] off leaves
  /// [version], unless one is given.
  GaiaChat copyWith({
    String? title,
    DateTime? lastMessageAt,
    bool? pinned,
    Map<String, GaiaAgentSession>? agentSessions,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
    bool touch = true,
  }) => GaiaChat(
    id: id,
    createdAt: createdAt,
    updatedAt: touch ? utcNow() : updatedAt,
    version: version ?? (bumpVersion ? this.version + 1 : this.version),
    deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    title: title ?? this.title,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    pinned: pinned ?? this.pinned,
    agentSessions: agentSessions ?? this.agentSessions,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toIso8601String(),
    'lastMessageAt': lastMessageAt.toIso8601String(),
    'pinned': pinned,
    'agentSessions': {
      for (final MapEntry(:key, :value) in agentSessions.entries)
        key: value.toJson(),
    },
  };

  factory GaiaChat.fromJson(Map<String, Object?> json) {
    final createdAt = DateTime.parse(json['createdAt']! as String);
    return GaiaChat(
      id: json['id']! as String,
      title: json['title']! as String,
      createdAt: createdAt,
      updatedAt: _date(json['updatedAt']) ?? createdAt,
      version: (json['version'] as num?)?.toInt() ?? 0,
      deletedAt: _date(json['deletedAt']),
      lastMessageAt: DateTime.parse(json['lastMessageAt']! as String),
      pinned: json['pinned'] == true,
      agentSessions: gaiaAgentSessionsFromJson(json['agentSessions']),
    );
  }
}

Map<String, GaiaAgentSession> gaiaAgentSessionsFromJson(Object? json) => {
  if (json is Map)
    for (final MapEntry(:key, :value) in json.entries)
      if (value is Map)
        key as String: GaiaAgentSession.fromJson(value.cast<String, Object?>()),
};

/// One piece of a message: text the agent wrote, or a run of tool calls
/// between text blocks, collapsed to their labels (§8.1).
sealed class GaiaPart {
  const GaiaPart();

  Map<String, Object?> toJson();

  factory GaiaPart.fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'text' => GaiaTextPart(json['text']! as String),
        'activity' => GaiaActivityPart((json['tools']! as List).cast<String>()),
        final type => throw FormatException('Unknown Gaia part: $type'),
      };
}

class GaiaTextPart extends GaiaPart {
  const GaiaTextPart(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'text': text};
}

class GaiaActivityPart extends GaiaPart {
  const GaiaActivityPart(this.tools);

  /// Tool names, in the order they were called.
  final List<String> tools;

  @override
  Map<String, Object?> toJson() => {'type': 'activity', 'tools': tools};
}

class GaiaMessage extends SoftDeletable {
  const GaiaMessage({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.chatId,
    required this.seq,
    required this.role,
    required this.parts,
    required this.status,
    this.model,
    this.error,
    this.needsInput = false,
  });

  final String chatId;
  final int seq;
  final GaiaMessageRole role;
  final List<GaiaPart> parts;
  final GaiaMessageStatus status;
  final String? model;

  /// What went wrong, for [GaiaMessageStatus.error].
  final String? error;

  /// A reply that ended on a question (§10.1): its notification says "Gaia
  /// has a question" rather than "done".
  final bool needsInput;

  String get text =>
      parts.whereType<GaiaTextPart>().map((part) => part.text).join('\n\n');

  /// [touch] and [bumpVersion] as on [GaiaChat.copyWith].
  GaiaMessage copyWith({
    List<GaiaPart>? parts,
    GaiaMessageStatus? status,
    String? error,
    bool? needsInput,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
    bool touch = true,
  }) => GaiaMessage(
    id: id,
    createdAt: createdAt,
    updatedAt: touch ? utcNow() : updatedAt,
    version: version ?? (bumpVersion ? this.version + 1 : this.version),
    deletedAt: deletedAt ?? this.deletedAt,
    chatId: chatId,
    seq: seq,
    role: role,
    parts: parts ?? this.parts,
    status: status ?? this.status,
    model: model,
    error: error ?? this.error,
    needsInput: needsInput ?? this.needsInput,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'chatId': chatId,
    'seq': seq,
    'role': role.name,
    'parts': [for (final part in parts) part.toJson()],
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toIso8601String(),
    'model': model,
    'error': error,
    'needsInput': needsInput,
  };

  factory GaiaMessage.fromJson(Map<String, Object?> json) {
    final createdAt = DateTime.parse(json['createdAt']! as String);
    return GaiaMessage(
      id: json['id']! as String,
      chatId: json['chatId']! as String,
      seq: json['seq']! as int,
      role: GaiaMessageRole.values.byName(json['role']! as String),
      parts: gaiaPartsFromJson(json['parts']! as List),
      status: GaiaMessageStatus.values.byName(json['status']! as String),
      createdAt: createdAt,
      updatedAt: _date(json['updatedAt']) ?? createdAt,
      version: (json['version'] as num?)?.toInt() ?? 0,
      deletedAt: _date(json['deletedAt']),
      model: json['model'] as String?,
      error: json['error'] as String?,
      needsInput: json['needsInput'] == true,
    );
  }
}

List<GaiaPart> gaiaPartsFromJson(List<Object?> json) => [
  for (final part in json)
    GaiaPart.fromJson((part! as Map).cast<String, Object?>()),
];

/// Whether [text]'s last paragraph is a question (§10.1), past any closing
/// emphasis, bracket or quote.
bool gaiaEndsWithQuestion(String text) {
  final paragraphs = text.trim().split(RegExp(r'\n\s*\n'));
  final last = paragraphs.last.trimRight().replaceFirst(
    RegExp(r'''[*_)\]"'”’`]+$'''),
    '',
  );
  return last.endsWith('?');
}

/// Gaia's settings (§8 `gaia_settings`): one record, [singletonId], synced.
class GaiaSettings extends SoftDeletable {
  const GaiaSettings({
    required super.createdAt,
    required super.updatedAt,
    super.version,
    this.gaiaMd = '',
    this.notifyOnDone = true,
  }) : super(id: singletonId);

  factory GaiaSettings.initial() {
    final now = utcNow();
    return GaiaSettings(createdAt: now, updatedAt: now);
  }

  static const singletonId = 'gaia';

  /// GAIA.md (§5.2): appended to every agent's system prompt, in place of
  /// the CLIs' own global instruction files.
  final String gaiaMd;

  /// A Windows toast when a run finishes while Gaia is hidden (§14).
  final bool notifyOnDone;

  GaiaSettings copyWith({String? gaiaMd, bool? notifyOnDone}) => GaiaSettings(
    createdAt: createdAt,
    updatedAt: utcNow(),
    version: version + 1,
    gaiaMd: gaiaMd ?? this.gaiaMd,
    notifyOnDone: notifyOnDone ?? this.notifyOnDone,
  );

  /// What the companion needs of them.
  Map<String, Object?> toJson() => {
    'gaiaMd': gaiaMd,
    'notifyOnDone': notifyOnDone,
  };
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.parse(value) : null;

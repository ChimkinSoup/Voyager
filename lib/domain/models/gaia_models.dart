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

/// The backends an agent runs on (§5.1). The Gemini CLI is deferred: its
/// login can't be tested yet.
const kGaiaClaudeCodeAdapter = 'claude_code';
const kGaiaCodexAdapter = 'codex';

/// The utility model's default (§5.1): Gemini Flash, the cheapest fast one.
const kGaiaDefaultUtilityModel = 'gemini-3.6-flash';

/// What the router (§7.2) goes by until the user edits it.
const kGaiaDefaultRouterRubric =
    'quick: a short factual question, a quick rewrite or translation, '
    'small talk.\n'
    'standard: most writing, explaining, everyday code and planning.\n'
    'deep: hard reasoning, a large or subtle coding task, careful analysis '
    'of something long, or anything the user says matters a lot.';

/// The key a chat's native session on [deviceId] is kept under. A session
/// lives on the machine that ran it, so each device has its own (§7.4).
String gaiaSessionKey(
  String deviceId, {
  String adapter = kGaiaClaudeCodeAdapter,
}) => '$deviceId/$adapter';

/// How much model a message wants (§7.1), each pointing at an agent.
enum GaiaTier {
  quick('Quick', '/quick'),
  standard('Standard', '/std'),
  deep('Deep', '/deep');

  const GaiaTier(this.label, this.command);

  final String label;

  /// Its inline command (§7.3).
  final String command;
}

/// A configured model on an adapter (§2), e.g. "Sonnet 5.5 via Claude Code".
/// Accounts come in Phase 7.
class GaiaAgent {
  const GaiaAgent({
    required this.id,
    required this.label,
    required this.adapter,
    required this.model,
  });

  final String id;
  final String label;

  /// One of the `kGaia…Adapter` ids.
  final String adapter;

  /// Pinned on every call (§5.1).
  final String model;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'adapter': adapter,
    'model': model,
  };

  factory GaiaAgent.fromJson(Map<String, Object?> json) => GaiaAgent(
    id: json['id']! as String,
    label: json['label']! as String,
    adapter: json['adapter']! as String,
    model: json['model']! as String,
  );
}

/// The agents a new install starts with: Claude Code's three models, one
/// per tier.
const kGaiaDefaultAgents = [
  GaiaAgent(
    id: 'haiku',
    label: 'Haiku 5.5',
    adapter: kGaiaClaudeCodeAdapter,
    model: 'claude-haiku-5-5',
  ),
  GaiaAgent(
    id: 'sonnet',
    label: 'Sonnet 5.5',
    adapter: kGaiaClaudeCodeAdapter,
    model: 'claude-sonnet-5-5',
  ),
  GaiaAgent(
    id: 'opus',
    label: 'Opus 5.5',
    adapter: kGaiaClaudeCodeAdapter,
    model: 'claude-opus-5-5',
  ),
];

const kGaiaDefaultTiers = {
  GaiaTier.quick: 'haiku',
  GaiaTier.standard: 'sonnet',
  GaiaTier.deep: 'opus',
};

List<GaiaAgent> gaiaAgentsFromJson(Object? json) => [
  if (json is List)
    for (final agent in json)
      GaiaAgent.fromJson((agent! as Map).cast<String, Object?>()),
];

Map<String, Object?> gaiaTiersToJson(Map<GaiaTier, String> tiers) => {
  for (final MapEntry(:key, :value) in tiers.entries) key.name: value,
};

/// Tiers this build doesn't know are dropped.
Map<GaiaTier, String> gaiaTiersFromJson(Object? json) => {
  if (json is Map)
    for (final tier in GaiaTier.values)
      if (json[tier.name] case final String agentId) tier: agentId,
};

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
    this.tier,
  });

  final String title;
  final DateTime lastMessageAt;
  final bool pinned;

  /// Keyed by [gaiaSessionKey].
  final Map<String, GaiaAgentSession> agentSessions;

  /// The tier the chat last used (§7.2); null before its first message.
  final GaiaTier? tier;

  /// The session this chat resumes on [deviceId] with [adapter], or null to
  /// start one.
  String? sessionOn(
    String deviceId, {
    String adapter = kGaiaClaudeCodeAdapter,
  }) => agentSessions[gaiaSessionKey(deviceId, adapter: adapter)]?.sessionId;

  /// [touch] off leaves [updatedAt] where it was; [bumpVersion] off leaves
  /// [version], unless one is given.
  GaiaChat copyWith({
    String? title,
    DateTime? lastMessageAt,
    bool? pinned,
    Map<String, GaiaAgentSession>? agentSessions,
    GaiaTier? tier,
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
    tier: tier ?? this.tier,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'tier': tier?.name,
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
      tier: gaiaTierFromName(json['tier']),
    );
  }
}

/// Null for no tier, or one this build doesn't know.
GaiaTier? gaiaTierFromName(Object? name) =>
    GaiaTier.values.where((tier) => tier.name == name).firstOrNull;

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
    this.adapter,
    this.error,
    this.needsInput = false,
    this.contextTokens,
  });

  final String chatId;
  final int seq;
  final GaiaMessageRole role;
  final List<GaiaPart> parts;
  final GaiaMessageStatus status;
  final String? model;

  /// The adapter that wrote a reply, so a switch to another vendor knows
  /// which turns its session never saw (§7.4).
  final String? adapter;

  /// What went wrong, for [GaiaMessageStatus.error].
  final String? error;

  /// A reply that ended on a question (§10.1): its notification says "Gaia
  /// has a question" rather than "done".
  final bool needsInput;

  /// The session's context when the reply finished, for the tier switch's
  /// warning (§7.5); null when the backend doesn't say.
  final int? contextTokens;

  String get text =>
      parts.whereType<GaiaTextPart>().map((part) => part.text).join('\n\n');

  /// [touch] and [bumpVersion] as on [GaiaChat.copyWith].
  GaiaMessage copyWith({
    List<GaiaPart>? parts,
    GaiaMessageStatus? status,
    String? error,
    bool? needsInput,
    int? contextTokens,
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
    adapter: adapter,
    error: error ?? this.error,
    needsInput: needsInput ?? this.needsInput,
    contextTokens: contextTokens ?? this.contextTokens,
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
    'adapter': adapter,
    'error': error,
    'needsInput': needsInput,
    'contextTokens': contextTokens,
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
      adapter: json['adapter'] as String?,
      error: json['error'] as String?,
      needsInput: json['needsInput'] == true,
      contextTokens: (json['contextTokens'] as num?)?.toInt(),
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

/// A slash command (§9.2): `/name args` expands to [template] on send,
/// with `$ARGUMENTS`, `$1`…`$9`, `$CLIPBOARD` and `$DATE` filled in. A
/// [standalone] one sends as soon as it's picked from the palette.
class GaiaCommand {
  const GaiaCommand({
    required this.name,
    required this.template,
    this.description = '',
    this.standalone = false,
  });

  /// Without the slash.
  final String name;
  final String template;
  final String description;
  final bool standalone;

  Map<String, Object?> toJson() => {
    'name': name,
    'template': template,
    'description': description,
    'standalone': standalone,
  };

  factory GaiaCommand.fromJson(Map<String, Object?> json) => GaiaCommand(
    name: json['name']! as String,
    template: json['template']! as String,
    description: json['description'] as String? ?? '',
    standalone: json['standalone'] == true,
  );
}

Map<String, String> gaiaKeybindsFromJson(Object? json) => {
  if (json is Map)
    for (final MapEntry(:key, :value) in json.entries)
      if (key is String && value is String) key: value,
};

List<GaiaCommand> gaiaCommandsFromJson(Object? json) => [
  if (json is List)
    for (final command in json)
      GaiaCommand.fromJson((command! as Map).cast<String, Object?>()),
];

/// Gaia's settings (§8 `gaia_settings`): one record, [singletonId], synced.
class GaiaSettings extends SoftDeletable {
  const GaiaSettings({
    required super.createdAt,
    required super.updatedAt,
    super.version,
    this.gaiaMd = '',
    this.notifyOnDone = true,
    this.agents = kGaiaDefaultAgents,
    this.tiers = kGaiaDefaultTiers,
    this.lastTier = GaiaTier.standard,
    this.utilityModel = kGaiaDefaultUtilityModel,
    this.utilityAcknowledged = false,
    this.autoRoute = true,
    this.routerRubric = '',
    this.commands = const [],
    this.keybinds = const {},
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

  final List<GaiaAgent> agents;

  /// Each tier's agent id (§7.1).
  final Map<GaiaTier, String> tiers;

  /// The tier a new chat starts on while there's no router (§7.2).
  final GaiaTier lastTier;

  /// The utility model (§5.1), on the API key saved on each device.
  final String utilityModel;

  /// The user accepts the utility slot's terms: their key is on a paid
  /// tier, or Google may use the prompts (§5.1). Off, there's no utility
  /// model.
  final bool utilityAcknowledged;

  /// The router picks a new chat's first tier (§7.2).
  final bool autoRoute;

  /// The router's rubric; empty for [kGaiaDefaultRouterRubric].
  final String routerRubric;

  /// The user's slash commands (§9.2).
  final List<GaiaCommand> commands;

  /// Rebound keys (§9.1, §15.1), by `GaiaKeybind` name: a combo such as
  /// `Ctrl+Alt+Space`, or empty for unbound. Keys not here keep their
  /// defaults.
  final Map<String, String> keybinds;

  /// [tier]'s agent; null when the tier has none, or its agent was removed.
  GaiaAgent? agentFor(GaiaTier tier) =>
      agents.where((agent) => agent.id == tiers[tier]).firstOrNull;

  GaiaSettings copyWith({
    String? gaiaMd,
    bool? notifyOnDone,
    List<GaiaAgent>? agents,
    Map<GaiaTier, String>? tiers,
    GaiaTier? lastTier,
    String? utilityModel,
    bool? utilityAcknowledged,
    bool? autoRoute,
    String? routerRubric,
    List<GaiaCommand>? commands,
    Map<String, String>? keybinds,
  }) => GaiaSettings(
    createdAt: createdAt,
    updatedAt: utcNow(),
    version: version + 1,
    gaiaMd: gaiaMd ?? this.gaiaMd,
    notifyOnDone: notifyOnDone ?? this.notifyOnDone,
    agents: agents ?? this.agents,
    tiers: tiers ?? this.tiers,
    lastTier: lastTier ?? this.lastTier,
    utilityModel: utilityModel ?? this.utilityModel,
    utilityAcknowledged: utilityAcknowledged ?? this.utilityAcknowledged,
    autoRoute: autoRoute ?? this.autoRoute,
    routerRubric: routerRubric ?? this.routerRubric,
    commands: commands ?? this.commands,
    keybinds: keybinds ?? this.keybinds,
  );

  /// What the companion needs of them.
  Map<String, Object?> toJson() => {
    'gaiaMd': gaiaMd,
    'notifyOnDone': notifyOnDone,
    'agents': [for (final agent in agents) agent.toJson()],
    'tiers': gaiaTiersToJson(tiers),
    'lastTier': lastTier.name,
    'utilityModel': utilityModel,
    'utilityAcknowledged': utilityAcknowledged,
    'autoRoute': autoRoute,
    'routerRubric': routerRubric,
    'commands': [for (final command in commands) command.toJson()],
    'keybinds': keybinds,
  };
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.parse(value) : null;

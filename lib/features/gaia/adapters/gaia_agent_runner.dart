import 'dart:convert';

import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

/// What every adapter reports of a turn (GAIA_HLD.md §5.1), whatever its
/// CLI or API prints: the agent's text and the tools it called.
sealed class GaiaAgentEvent {
  const GaiaAgentEvent();
}

/// A text block of the agent's own reply has started. [block] is its place
/// in the model message, for a backend that can abandon blocks
/// ([GaiaBlocksAbandoned]).
class GaiaTextStart extends GaiaAgentEvent {
  const GaiaTextStart({this.block});

  final int? block;
}

/// A model message has started: [GaiaTextStart.block] and
/// [GaiaToolUse.block] count from it.
class GaiaMessageStart extends GaiaAgentEvent {
  const GaiaMessageStart();
}

/// A model call failed, and the backend tries it again after [delay]:
/// [attempt] of at most [maxRetries]. [status] is the HTTP status it
/// failed with; null when it never got one, as when the connection was lost.
class GaiaRetrying extends GaiaAgentEvent {
  const GaiaRetrying({
    required this.attempt,
    required this.maxRetries,
    this.status,
    this.delay,
  });

  final int attempt;
  final int maxRetries;
  final int? status;

  /// Null when the backend doesn't say.
  final Duration? delay;
}

/// The current model message's stream was cut off, and its blocks from
/// [from] on are thrown away: the backend asks again, and what streamed of
/// them isn't the reply.
class GaiaBlocksAbandoned extends GaiaAgentEvent {
  const GaiaBlocksAbandoned(this.from);

  final int from;
}

class GaiaTextDelta extends GaiaAgentEvent {
  const GaiaTextDelta(this.text);

  final String text;
}

/// The agent called a tool. [detail] is what it was called with, and
/// [failure] why it failed, when those are known already; otherwise a
/// [GaiaToolDetails] or [GaiaToolFailures] naming [id] brings them later.
/// [block] is as [GaiaTextStart.block].
class GaiaToolUse extends GaiaAgentEvent {
  const GaiaToolUse(
    this.name, {
    this.id,
    this.detail,
    this.failure,
    this.block,
  });

  final String name;
  final String? id;
  final int? block;
  final String? detail;
  final String? failure;
}

/// Tools already reported by a [GaiaToolUse] that failed, by their ids, with
/// why in brief.
class GaiaToolFailures extends GaiaAgentEvent {
  const GaiaToolFailures(this.failures);

  final Map<String, String> failures;
}

/// At most this many characters of why a tool call failed are kept.
const kGaiaToolFailureMax = 120;

/// [text]'s first non-empty line, clipped to [kGaiaToolFailureMax]; [orElse]
/// when it has none.
String gaiaToolFailure(Object? text, [String orElse = 'Failed']) {
  final line = text is String
      ? text
            .split('\n')
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty, orElse: () => '')
      : '';
  if (line.isEmpty) return orElse;
  return line.length <= kGaiaToolFailureMax
      ? line
      : '${line.substring(0, kGaiaToolFailureMax)}…';
}

/// What tools already reported by a [GaiaToolUse] were called with, by their
/// ids, once their input has come in whole.
class GaiaToolDetails extends GaiaAgentEvent {
  const GaiaToolDetails(this.details);

  final Map<String, String> details;
}

/// At most this many characters of a tool call's detail are kept: it's
/// saved and synced with the reply.
const kGaiaToolDetailMax = 500;

/// [input]'s gist for an activity part: the first of [keys] it has as a
/// non-empty string, or with none of them, all of it as compact JSON.
/// Clipped to [kGaiaToolDetailMax]; null when there's nothing to show.
String? gaiaToolDetail(Object? input, [List<String> keys = const []]) {
  if (input is! Map) return null;
  String? detail;
  for (final key in keys) {
    if (input[key] case final String value when value.trim().isNotEmpty) {
      detail = value.trim();
      break;
    }
  }
  if (detail == null && input.isNotEmpty) {
    try {
      detail = jsonEncode(input);
    } on JsonUnsupportedObjectError {
      return null;
    }
  }
  return gaiaClipDetail(detail);
}

/// [detail] trimmed and clipped to [kGaiaToolDetailMax]; null when there's
/// nothing to show.
String? gaiaClipDetail(String? detail) {
  final trimmed = detail?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.length <= kGaiaToolDetailMax
      ? trimmed
      : '${trimmed.substring(0, kGaiaToolDetailMax)}…';
}

/// A card was raised, or decided (§10): one with a new id goes after the
/// reply so far, one already there is replaced where it is.
class GaiaCardUpdate extends GaiaAgentEvent {
  const GaiaCardUpdate(this.card, {this.saveNow = true});

  final GaiaCardPart card;

  /// Saved at once, rather than with the reply's next save: what another
  /// device or the Gaia page waits on (GAIA_AUTONOMY_HLD.md §7).
  final bool saveNow;
}

/// The account's usage, as the backend reported it mid-turn.
class GaiaUsageUpdate extends GaiaAgentEvent {
  const GaiaUsageUpdate(this.usage);

  final GaiaUsage usage;
}

/// The end of a turn. [isError] covers failures the backend reports as a
/// reply, such as an unknown model, with [text] saying what went wrong.
class GaiaTurnResult {
  const GaiaTurnResult({
    required this.sessionId,
    required this.isError,
    required this.text,
    this.contextTokens,
    this.contextWindow,
    this.sessionFound = true,
    this.notice,
  });

  /// The native session to resume next time.
  final String sessionId;

  /// False when a resume found no session: [sessionId] is then only the one
  /// asked for, and resuming it again fails the same way.
  final bool sessionFound;
  final bool isError;
  final String text;

  /// How many tokens the session's context held at the turn's last model
  /// call; null when the backend doesn't say.
  final int? contextTokens;

  /// The model's context window in tokens; null when the backend doesn't say.
  final int? contextWindow;

  /// Something the user should hear about the session, beside the reply:
  /// a take-back ([GaiaAgentRunner.takeBack]) that didn't hold.
  final String? notice;
}

/// A turn that ended without a result: the process died, or its output
/// couldn't be read.
class GaiaRunException implements Exception {
  GaiaRunException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An image going with a turn (§9.3): the `[image N]` it's referred to by,
/// and the file holding it.
typedef GaiaImageInput = ({int label, String path, String mimeType});

/// Runs chats on one backend. One runner per adapter; the model is chosen
/// per turn, since a chat's tier can change between turns (§7.4).
abstract interface class GaiaAgentRunner {
  /// Starts a turn in [chatId]'s session: [sessionId] resumes one, null
  /// starts one. [images] go with [prompt], which names them by their
  /// `[image N]` tokens. [directories] are the folders the chat's attached
  /// files and folders are in, which the agent must be let read. [tools]
  /// answers the turn's calls to Gaia's tools and its CLI's permission
  /// prompts (§5.3); null offers none. [sessionInstructions] go after
  /// GAIA.md in a new session's system prompt (the memory index, §11); a
  /// resumed session keeps those it started with, since neither CLI takes
  /// new ones on a resume. [account] is the login it runs on (§6.1); null for
  /// the one Voyager was started with. [promptId] is the user message's id,
  /// which a backend that can names the prompt by in its session
  /// (GAIA_FORKING_HLD.md §5.1); null for one of its own. [effort] is the
  /// agent's thinking level ([GaiaAgent.effort]); null for the CLI's default.
  /// [fork], with a null [sessionId], makes the new session a native fork of
  /// another chat's (§5.3), for a backend that can; one that can't make it
  /// reports [GaiaTurnResult.sessionFound] false. [onEvent] gets each event
  /// of the turn; the future completes with its result, or throws a
  /// [GaiaRunException].
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    String? effort,
    required String prompt,
    List<GaiaImageInput> images = const [],
    Set<String> directories = const {},
    GaiaTurnTools? tools,
    String sessionInstructions = '',
    GaiaAccount? account,
    String? promptId,
    GaiaForkCut? fork,
    required void Function(GaiaAgentEvent event) onEvent,
  });

  bool isRunning(String chatId);

  /// GAIA.md changed (§5.2).
  Future<void> setInstructions(String text);

  /// Kills [chatId]'s run; its turn fails.
  Future<void> stop(String chatId);

  /// Takes the turn [stop] just ended for [chatId] back out of its session,
  /// so the session's next turn goes on as if it was never sent (§9.6).
  /// Null once it's out, or when the session never got it; otherwise why
  /// not, and the session still has it.
  Future<String?> takeBack(String chatId);

  /// Kills every run this runner started.
  Future<void> killAll();
}

/// A runner holding its own copy of each account's login (§6.1).
abstract interface class GaiaAccountKeeper {
  /// Stops what's running for, and drops the login of, any account but
  /// [accounts]. A run going finishes first.
  Future<void> keepAccounts(Iterable<GaiaAccount> accounts);
}

/// A runner whose native sessions can follow a chat to another account
/// (§6.5).
abstract interface class GaiaSessionCopier {
  /// Copies [sessionId] from [from]'s store into [to]'s, so a turn on [to]
  /// can resume it. False when [from] doesn't have it.
  Future<bool> copySession({
    required String sessionId,
    required GaiaAccount from,
    required GaiaAccount to,
  });
}

/// Where a fork's session branches off its source chat's (GAIA_FORKING_HLD.md
/// §5.3): [sessionId], kept up to [keepAt], Claude Code's entry or Codex's
/// turn (GAIA_REWIND_HLD.md §10.2).
typedef GaiaForkCut = ({String sessionId, String keepAt});

/// A runner whose native sessions can be forked (GAIA_FORKING_HLD.md §5).
abstract interface class GaiaSessionForker {
  /// The entry a fork of [chatId]'s [sessionId] on [account] keeps up to
  /// (§5.2): just before the first of [next] the session has, or with none,
  /// [endAt], or with none of that either, its end. [after] must be in it:
  /// the last prompt the fork's session answers. [awaiting], a prompt just
  /// sent, is waited for a few seconds. Null when it can't be found.
  Future<String?> forkCut({
    required String chatId,
    required String sessionId,
    required GaiaAccount account,
    required String after,
    required List<String> next,
    String? awaiting,
    String? endAt,
  });

  /// [chatId]'s sessions now belong to [forkId], a rewind's auto-fork
  /// (GAIA_REWIND_HLD.md §4): [chatId]'s idle process is let go, and a
  /// take-back's cut still to be made goes to [forkId] with its session.
  Future<void> rewound(String chatId, String forkId);
}

/// A `/` command the CLI runs itself (GAIA_NATIVE_COMMANDS.md): its name
/// without the slash, what it does, and what it takes after it.
typedef GaiaNativeCommand = ({
  String name,
  String description,
  String argumentHint,
});

/// A runner whose CLI has `/` commands of its own (GAIA_NATIVE_COMMANDS.md).
/// A message starting with one goes to the runner as typed, and the runner
/// has its CLI run it.
abstract interface class GaiaNativeCommander {
  /// [account]'s commands, less those Gaia keeps out (§4); empty when they
  /// can't be read.
  Future<List<GaiaNativeCommand>> nativeCommands(GaiaAccount? account);
}

typedef GaiaCliVersion = (int, int, int);

/// The first `x.y.z` in a CLI's `--version` output.
GaiaCliVersion? parseCliVersion(String output) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(output);
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

/// Whether [version] is at least the range's first and below its second.
bool isVersionInRange(
  GaiaCliVersion version,
  (GaiaCliVersion, GaiaCliVersion) range,
) {
  int compare(GaiaCliVersion a, GaiaCliVersion b) =>
      a.$1 != b.$1 ? a.$1 - b.$1 : (a.$2 != b.$2 ? a.$2 - b.$2 : a.$3 - b.$3);
  final (low, high) = range;
  return compare(version, low) >= 0 && compare(version, high) < 0;
}

/// Builds a reply's parts from a turn's events: text blocks in order, with
/// each run of tool calls between them collapsed to an activity part (§8.1).
class GaiaTurnBuilder {
  final _parts = <GaiaPart>[];

  /// Where each tool call with an id is: its activity part's place in
  /// [_parts], and its own in that part.
  final _calls = <String, (int, int)>{};

  /// [_parts] and [_calls] as each numbered block of the current model
  /// message started, by its number: what a [GaiaBlocksAbandoned] goes back
  /// to.
  final _marks = <int, (List<GaiaPart>, Map<String, (int, int)>)>{};

  List<GaiaPart> get parts => List.unmodifiable(_parts);

  void _mark(int? block) {
    if (block != null) _marks[block] = (List.of(_parts), Map.of(_calls));
  }

  /// Applies [event]; true when [parts] changed.
  bool apply(GaiaAgentEvent event) {
    switch (event) {
      case GaiaMessageStart():
        _marks.clear();
        return false;
      case GaiaBlocksAbandoned(:final from):
        final blocks = _marks.keys.where((block) => block >= from).toList()
          ..sort();
        // None shown, as for a thinking block: nothing to take back.
        if (blocks.isEmpty) return false;
        final (parts, calls) = _marks[blocks.first]!;
        _marks.clear();
        _parts
          ..clear()
          ..addAll(parts);
        _calls
          ..clear()
          ..addAll(calls);
      case GaiaTextStart(:final block):
        _mark(block);
        _parts.add(const GaiaTextPart(''));
      case GaiaTextDelta(:final text):
        if (_parts.lastOrNull case GaiaTextPart(text: final sofar)) {
          _parts.last = GaiaTextPart(sofar + text);
        } else {
          _parts.add(GaiaTextPart(text));
        }
      case GaiaToolUse(
        :final name,
        :final id,
        :final detail,
        :final failure,
        :final block,
      ):
        _mark(block);
        if (_parts.lastOrNull is! GaiaActivityPart) {
          _parts.add(const GaiaActivityPart([]));
        }
        final part = _parts.last as GaiaActivityPart;
        if (id != null) _calls[id] = (_parts.length - 1, part.tools.length);
        _parts.last = part.adding(
          name,
          detail: detail,
          failure: failure,
          id: kGaiaKeptResultTools.contains(name) ? id : null,
        );
      case GaiaToolDetails(:final details):
        return _update(
          details,
          (part, call) => part.detailAt(call),
          (part, call, detail) => part.withCall(call, detail: detail),
        );
      case GaiaToolFailures(:final failures):
        return _update(
          failures,
          (part, call) => part.failureAt(call),
          (part, call, failure) => part.withCall(call, failure: failure),
        );
      case GaiaCardUpdate(:final card):
        final index = _parts.indexWhere(
          (part) => part is GaiaCardPart && part.id == card.id,
        );
        if (index < 0) {
          _parts.add(card);
        } else {
          _parts[index] = card;
        }
      case GaiaUsageUpdate() || GaiaRetrying():
        return false;
    }
    return true;
  }

  /// Sets each call in [values] by its id with [set], where [get] has it
  /// otherwise; true when any changed. Ids not seen are skipped.
  bool _update(
    Map<String, String> values,
    String? Function(GaiaActivityPart part, int call) get,
    GaiaActivityPart Function(GaiaActivityPart part, int call, String value)
    set,
  ) {
    var changed = false;
    for (final MapEntry(key: id, :value) in values.entries) {
      final (index, call) = _calls[id] ?? (-1, -1);
      if (index < 0) continue;
      final part = _parts[index] as GaiaActivityPart;
      if (get(part, call) == value) continue;
      _parts[index] = set(part, call, value);
      changed = true;
    }
    return changed;
  }

  /// [parts] without text blocks that ended up empty.
  List<GaiaPart> get finished => [
    for (final part in _parts)
      if (part is! GaiaTextPart || part.text.isNotEmpty) part,
  ];
}

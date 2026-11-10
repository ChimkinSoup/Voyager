// FRAGILE(cli): the Claude Code invocation, its stdin message shape
// (`--input-format stream-json`), and the control protocol on the same
// channel: the `initialize` request that registers Gaia's tools as an
// `sdk` MCP server, and the `control_response`s answering the CLI's
// `mcp_message` and `can_use_tool` requests (observed on 2.1.312; the
// Agent SDK's own protocol, undocumented). See claude_code_events.dart.
//
// FRAGILE(cli): taking a stopped turn back (GAIA_HLD.md §9.6) leans on two
// flags `claude --help` hides, found in the CLI's own source and checked on
// 2.1.318:
//   --resume-session-at <entry uuid>: a resume keeps the session only up to
//     that entry; the next prompt branches from it, and a later plain
//     --resume follows the branch.
//   --resume-drops-turn <prompt uuid>: with the above in print mode, the
//     resume is refused (an error result, then exit) unless all it cuts is
//     that prompt's turn.
// And on the `uuid` a stream-json user message carries becoming its entry's
// uuid in the session JSONL, whose `uuid`/`parentUuid`/`timestamp` fields
// are read here. Each step is checked rather than trusted: a resume with
// the flags is started before the prompt goes back, and refused or not
// understood it keeps the message in the chat; the next turn's entry must
// hang off the kept one, or the user is told the session may still have it.
//
// FRAGILE(cli): forking a chat natively (GAIA_FORKING_HLD.md §5) leans on
// `--resume <id> --fork-session --resume-session-at <entry uuid>` making a
// new session, under a new id its `init` names, holding the source only up
// to that entry, and on a bad entry uuid exiting before `init` (checked on
// 2.1.318). The fork's first prompt must then hang off the entry; if it
// doesn't, the user is told.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

const _uuid = Uuid();

/// Keys stripped from the CLI's environment, so a stray API key never moves
/// a subscription login onto API billing.
const _strippedEnvironment = {'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN'};

/// The CLI's environment: Voyager's own less [_strippedEnvironment], with
/// [configDir] as `CLAUDE_CONFIG_DIR` (the account, §6.1) when it's set.
Map<String, String> claudeEnvironment(String configDir) {
  final dir = configDir.trim();
  return {
    for (final MapEntry(:key, :value) in Platform.environment.entries)
      if (!_strippedEnvironment.contains(key.toUpperCase()) &&
          !(dir.isNotEmpty && key.toUpperCase() == 'CLAUDE_CONFIG_DIR'))
        key: value,
    if (dir.isNotEmpty) 'CLAUDE_CONFIG_DIR': dir,
  };
}

/// The folder [configDir] means: itself, or with none set, the one the CLI
/// falls back on.
String claudeConfigRoot(String configDir) {
  final dir = configDir.trim();
  final environment = Platform.environment;
  return dir.isNotEmpty
      ? dir
      : environment['CLAUDE_CONFIG_DIR'] ??
            p.join(environment['USERPROFILE'] ?? '', '.claude');
}

/// A user message's `content` (§9.3): [prompt] alone, or with [images] as
/// content blocks interleaved where their `[image N]` tokens are, each after
/// the text that ends in its token. An image whose token isn't in [prompt]
/// goes at the end, after its token.
Future<Object> claudeUserContent(
  String prompt,
  List<GaiaImageInput> images,
) async {
  if (images.isEmpty) return prompt;
  final byLabel = {for (final image in images) image.label: image};
  final blocks = <Map<String, Object?>>[];
  void text(String text) {
    if (text.trim().isNotEmpty) blocks.add({'type': 'text', 'text': text});
  }

  Future<void> image(GaiaImageInput image) async => blocks.add({
    'type': 'image',
    'source': {
      'type': 'base64',
      'media_type': image.mimeType,
      'data': base64Encode(await File(image.path).readAsBytes()),
    },
  });

  var from = 0;
  for (final match in gaiaImageTokenPattern.allMatches(prompt)) {
    final input = byLabel.remove(int.parse(match.group(1)!));
    if (input == null) continue;
    text(prompt.substring(from, match.end));
    from = match.end;
    await image(input);
  }
  text(prompt.substring(from));
  for (final input in byLabel.values) {
    text(gaiaImageToken(input.label));
    await image(input);
  }
  return blocks;
}

const _idleTimeout = Duration(minutes: 10);

/// How long a fork waits for a prompt just sent to reach the session file.
const _forkWait = Duration(seconds: 5);
const _maxLive = 4;

/// Gaia's tools, served by Gaia itself over the control channel (§5.3):
/// safe mode leaves out every MCP server a config names, a stdio one
/// included, but not an `sdk` one (checked on 2.1.312).
const _mcpConfig =
    '{"mcpServers":{"$kGaiaMcpServer":'
    '{"type":"sdk","name":"$kGaiaMcpServer"}}}';

/// Claude Code's own commands Gaia doesn't run, aliases included, with why
/// (GAIA_NATIVE_COMMANDS.md §4): they'd change the session or a setting
/// behind Gaia's back, cost money, or do nothing in a headless chat.
const kClaudeBlockedCommands = {
  'clear': "it starts a new Claude Code session Gaia wouldn't follow. Use /new",
  'reset': "it starts a new Claude Code session Gaia wouldn't follow. Use /new",
  'model': "it lasts only until Gaia restarts the process. Use Gaia's tiers",
  'effort': "it lasts only until Gaia restarts the process. Use Gaia's tiers",
  'advisor': 'it lasts only until Gaia restarts the process',
  'fast': "fast mode isn't available to Gaia's Claude Code",
  'rename': 'Gaia names its own chats',
  'name': 'Gaia names its own chats',
  'config': "it changes Claude Code's settings for every chat",
  'settings': "it changes Claude Code's settings for every chat",
  'output-style': "it changes Claude Code's settings for every chat",
  'autocompact': "it changes Claude Code's settings for every chat",
  'auto-mode-setup': "Gaia answers Claude Code's permission prompts itself",
  'mcp': "it can turn off Gaia's own tools",
  'init': "it writes a CLAUDE.md into Gaia's workspace, for every chat",
  'import': "it copies other agents' settings into Claude Code's",
  'design': "it changes your account's Design access",
  'design-consent': "it changes your account's Design access",
  'design-revoke': "it changes your account's Design access",
  'usage-credits': "it changes your account's billing",
  'extra-usage': "it changes your account's billing",
  'ultrareview': 'it starts a paid cloud review',
  'loop': "it stops when Gaia's idle process does",
  'goal': "it keeps Claude Code working past Gaia's turn",
  'color': 'it only colours the terminal',
  'focus': 'it only changes the terminal view',
  'heapdump': "it's for debugging Claude Code itself",
  'agents': 'Claude Code removed it',
  'reload-plugins': "Gaia's Claude Code runs without plugins",
  '__remote-workflow': 'it only runs in cloud sessions',
  'workflow-launch-exec': 'it only runs in cloud sessions',
};

/// The blocked command [prompt] starts with, by name; null when it starts
/// with none.
String? claudeBlockedCommandIn(String prompt) {
  final name = RegExp(r'^/([\w-]+)(?:\s|$)').firstMatch(prompt.trim());
  return kClaudeBlockedCommands.containsKey(name?.group(1))
      ? name!.group(1)
      : null;
}

/// What a turn that ran a command the CLI handles itself shows, when nothing
/// streamed (GAIA_NATIVE_COMMANDS.md §5): its output, or for `/compact`,
/// how far the session shrank.
String claudeCommandOutput(String result, ClaudeCompacted? compacted) {
  // Laid out for a terminal, so kept monospace with its line breaks, in a
  // fence longer than any backtick run inside it.
  if (result.trim().isNotEmpty) {
    final runs = RegExp('`+').allMatches(result).map((m) => m[0]!.length);
    final fence = '`' * (runs.fold(2, (a, b) => a > b ? a : b) + 1);
    // Blank lines go from the ends, but the first line keeps its indent.
    final body = result.replaceFirst(RegExp(r'^\s*\n'), '').trimRight();
    return '$fence\n$body\n$fence';
  }
  if (compacted == null) return '';
  String tokens(int n) => n < 1000 ? '$n' : '${(n / 1000).toStringAsFixed(1)}k';
  return switch (compacted) {
    ClaudeCompacted(preTokens: final pre?, postTokens: final post?) =>
      'Compacted: ${tokens(pre)} → ${tokens(post)} tokens.',
    _ => 'Compacted.',
  };
}

/// A stopped turn taken back (§9.6): [sessionId] resumed only up to the
/// entry [keepAt], cutting the turn of the prompt [drops].
typedef _Rewind = ({String sessionId, String keepAt, String drops});

extension on _Rewind {
  List<String> get args => [
    '--resume-session-at',
    keepAt,
    '--resume-drops-turn',
    drops,
  ];
}

/// A turn [ClaudeCodeRunner.stop] ended: its prompt's uuid, when it went,
/// and the process it went to.
typedef _StoppedTurn = ({
  String sessionId,
  String prompt,
  DateTime sentAt,
  _ClaudeProcess process,
});

/// Runs chats on the Claude Code CLI: one long-lived process per active chat,
/// whose stdin stays open across turns. A process idle for 10 minutes is
/// killed and the next message resumes its session; past four live, the
/// least recently used goes. The model is pinned per process (§5.1): a turn
/// on another model restarts the process, resuming the same session (§7.4).
///
/// Every process runs in safe mode, which leaves out the user's global
/// CLAUDE.md, hooks and plugins (§5.2: `--setting-sources` doesn't keep
/// CLAUDE.md out, checked on 2.1.310), with GAIA.md appended to the system
/// prompt from [instructionsFile], or, with a session's own instructions
/// after it (§11), from that chat's file beside it in `sessions`.
///
/// Gaia is each process's SDK host (§5.3): its tools are an MCP server the
/// CLI reaches through `control_request`s on stdout, and the permission
/// prompts the CLI would show come the same way, for a card. The turn's
/// [GaiaTurnTools] answers each. Claude Code's own `AskUserQuestion` is
/// left out, for `ask_user` (§10.1): as a host, Gaia would be offered it.
class ClaudeCodeRunner
    implements
        GaiaAgentRunner,
        GaiaSessionCopier,
        GaiaSessionForker,
        GaiaNativeCommander {
  ClaudeCodeRunner({
    required this.workingDirectory,
    required this.instructionsFile,
    this.onLine,
  });

  final String workingDirectory;

  /// Where GAIA.md is written for `--append-system-prompt-file`: a file
  /// rather than the text itself, which `cmd /c` would mangle.
  final String instructionsFile;
  var _instructions = '';

  /// Every line the CLI prints, before it's parsed: for the CLI contract
  /// check (`qa/harness/gaia_cli_check.ps1`).
  final void Function(String line)? onLine;

  /// Live processes by chat id, least recently used first.
  final _live = <String, _ClaudeProcess>{};

  /// The turn [stop] last caught mid-run, by chat, for [takeBack].
  final _stopped = <String, _StoppedTurn>{};

  /// Chats whose turn is on its way to a process, not yet sent.
  final _starting = <String>{};

  /// Chats stopped while [_starting]: the turn fails before its prompt goes,
  /// so [takeBack] has nothing to take.
  final _stoppedStarting = <String>{};

  /// Taken-back turns not yet cut, by chat: the next process resuming the
  /// session does it (see the FRAGILE note above). On disk, so a companion
  /// restart before then still does.
  Map<String, _Rewind>? _rewinds;
  Future<void> _writing = Future.value();
  File get _rewindsFile =>
      File(p.join(p.dirname(instructionsFile), 'claude-rewinds.json'));

  @override
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
    bool toolless = false,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    // Kept from the CLI even typed past the palette (GAIA_NATIVE_COMMANDS.md
    // §4).
    if (claudeBlockedCommandIn(prompt) case final name?) {
      return GaiaTurnResult(
        sessionId: sessionId ?? '',
        isError: true,
        text:
            "Gaia doesn't run Claude Code's /$name: "
            '${kClaudeBlockedCommands[name]}.',
      );
    }
    final newSessionId = sessionId ?? _uuid.v4();
    // Whether the reply streamed any text, and the compaction a `/compact`
    // made: a command the CLI runs itself streams none (§5).
    var streamed = false;
    ClaudeCompacted? compacted;
    // Sent twice with the same [promptId] only when the first attempt never
    // started its session, so never saved the prompt: a session never holds
    // two entries with one uuid (GAIA_FORKING_HLD.md §5.1).
    Future<(ClaudeResult, bool, String?, String?)> attempt() => _send(
      chatId: chatId,
      sessionId: sessionId,
      newSessionId: newSessionId,
      model: model,
      effort: effort,
      prompt: prompt,
      images: images,
      directories: directories,
      tools: tools,
      sessionInstructions: sessionInstructions,
      configDir: account?.dir ?? '',
      promptId: promptId,
      fork: fork,
      toolless: toolless,
      onEvent: (event) {
        if (event is ClaudeTextDelta) streamed = true;
        if (event is ClaudeCompacted) compacted = event;
        if (gaiaEventOf(event) case final event?) onEvent(event);
      },
    );
    var (result, started, sessionModel, notice) = await attempt();
    // No session with a take-back's cut: refused, say as the session changed
    // since the cut was checked, or gone. Once more as it is, so a refusal
    // doesn't lose the session; one that's gone is still not found.
    if (_rewinds?[chatId] case final cut?
        when !started && cut.sessionId == sessionId) {
      _rewinds!.remove(chatId);
      await _writeRewinds();
      (result, started, sessionModel, notice) = await attempt();
      if (started) {
        notice ??=
            'Claude Code may still remember the message you stopped '
            "earlier: it wouldn't resume from before it.";
      }
    }
    // A command the CLI ran itself: its output comes whole, in the result.
    if (!result.isError && !streamed && prompt.trimLeft().startsWith('/')) {
      final output = claudeCommandOutput(result.text, compacted);
      if (output.isNotEmpty) {
        onEvent(const GaiaTextStart());
        onEvent(GaiaTextDelta(output));
      }
    }
    return GaiaTurnResult(
      sessionId: result.sessionId,
      isError: result.isError,
      text: result.text,
      contextTokens: result.contextTokens,
      contextWindow: result.contextWindowOf(sessionModel),
      sessionFound: started,
      notice: notice,
    );
  }

  /// [send] with the CLI's own events, and the id a new session gets: for
  /// the CLI contract check.
  Future<ClaudeResult> sendRaw({
    required String chatId,
    required String? sessionId,
    required String newSessionId,
    required String model,
    required String prompt,
    List<GaiaImageInput> images = const [],
    GaiaTurnTools? tools,
    String sessionInstructions = '',
    String configDir = '',
    String? promptId,
    required void Function(ClaudeEvent event) onEvent,
  }) async => (await _send(
    chatId: chatId,
    sessionId: sessionId,
    newSessionId: newSessionId,
    model: model,
    effort: null,
    prompt: prompt,
    images: images,
    directories: const {},
    tools: tools,
    sessionInstructions: sessionInstructions,
    configDir: configDir,
    promptId: promptId,
    fork: null,
    toolless: false,
    onEvent: onEvent,
  )).$1;

  /// [sendRaw], whether the process got as far as a session (a resume that
  /// finds none ends in an error result without an `init`), the model its
  /// `init` named, and a [GaiaTurnResult.notice]. A [fork] refused before
  /// its `init` is an error result, not started.
  Future<(ClaudeResult, bool, String?, String?)> _send({
    required String chatId,
    required String? sessionId,
    required String newSessionId,
    required String model,
    required String? effort,
    required String prompt,
    required List<GaiaImageInput> images,
    required Set<String> directories,
    required GaiaTurnTools? tools,
    required String sessionInstructions,
    required String configDir,
    required String? promptId,
    required GaiaForkCut? fork,
    required bool toolless,
    required void Function(ClaudeEvent event) onEvent,
  }) async {
    // Only a new session is made as a fork.
    final forking = sessionId == null ? fork : null;
    // Before anything's awaited: a stop from here on is caught.
    _starting.add(chatId);
    _stoppedStarting.remove(chatId);
    final content = await claudeUserContent(prompt, images);
    // A stop's turn is only taken back straight after it.
    _stopped.remove(chatId);
    final rewinds = await _readRewinds();
    var cut = rewinds[chatId];
    if (cut != null && cut.sessionId != sessionId) {
      // The chat has moved on to another session, which never had the turn.
      rewinds.remove(chatId);
      await _writeRewinds();
      cut = null;
    }
    var process = _live.remove(chatId);
    String? sessionFile;
    // One that never started a session (a resume that found none) is on
    // its way out. Directories are fixed per process too: one that can't
    // read a newly attached file restarts, resuming the session. A
    // session's own instructions aren't: a resume keeps those it started
    // with, whatever file it's given (checked on 2.1.314). The account is
    // fixed too: a chat that moved to another resumes its copy of the session
    // there (§6.5). A fork is always a process of its own, and so is a new
    // session: a fork's failed first turn is retried as one (§10.5). So is
    // the effort, a flag like the model.
    if (process != null &&
        (process.sessionId != sessionId ||
            process.model != model ||
            process.effort != effort ||
            process.configDir != configDir ||
            !process.started ||
            (cut != null && process.cut != cut) ||
            !process.directories.containsAll(directories))) {
      // Gone before another resumes its session.
      await process.kill();
      process = null;
    }
    if (process == null || process.exited) {
      // Never one mid-turn: past four running at once, there are just more.
      while (_live.length >= _maxLive) {
        final idle = _live.keys.where((id) => !_live[id]!.inTurn).firstOrNull;
        if (idle == null) break;
        unawaited(_live.remove(idle)!.kill());
      }
      final instructions = await _instructionsFileFor(
        chatId,
        sessionInstructions,
      );
      if (instructions != instructionsFile) sessionFile = instructions;
      process = await _ClaudeProcess.start(
        workingDirectory: workingDirectory,
        model: model,
        effort: effort,
        configDir: configDir,
        onLine: onLine,
        directories: directories,
        // A fork's is the one its `init` names.
        sessionId: sessionId ?? newSessionId,
        cut: cut,
        fork: forking,
        toolless: toolless,
        sessionArgs: [
          if (instructions != null) ...[
            '--append-system-prompt-file',
            instructions,
          ],
          ...switch ((sessionId, forking)) {
            (final String id, _) => ['--resume', id, ...?cut?.args],
            (null, final fork?) => [
              '--resume',
              fork.sessionId,
              '--fork-session',
              '--resume-session-at',
              fork.keepAt,
            ],
            (null, null) => ['--session-id', newSessionId],
          },
        ],
      );
    }
    // From here to the prompt going, nothing's awaited: a stop finds it live.
    _starting.remove(chatId);
    _live[chatId] = process;
    // The session after a turn on a cut process: read once for both checks.
    List<Map<String, Object?>>? entries;
    try {
      if (_stoppedStarting.contains(chatId)) {
        await process.kill();
        throw GaiaRunException('Stopped.');
      }
      ClaudeResult result;
      try {
        result = await process.turn(content, tools, onEvent, promptId);
      } on GaiaRunException catch (error) {
        if (forking == null || process.started || process.killed) rethrow;
        // Refused before its prompt reached the model, say for a cut the
        // source doesn't have (§6): the caller sends it again unforked.
        debugPrint('[gaia] fork of ${forking.sessionId} refused: $error');
        result = ClaudeResult(sessionId: '', isError: true, text: '$error');
      }
      String? notice;
      if (process.cut case final cut? when process.started) {
        entries = await _sessionEntries(process.configDir, cut.sessionId);
        notice = _checkCut(cut, process, entries);
      }
      if (forking != null && process.started) {
        notice = _checkFork(
          forking,
          process,
          await _sessionEntries(process.configDir, process.sessionId),
        );
      }
      return (result, process.started, process.sessionModel, notice);
    } finally {
      // Once its session has the prompt's entry, the turn branches off the
      // cut: a later process resumes as it is. One stopped before the entry
      // was written keeps the cut for the next. One saved under another id
      // (told of by [_checkCut]) branched too, or never will: not cut again.
      if (process.cut case final cut? when process.started) {
        entries ??= await _sessionEntries(process.configDir, cut.sessionId);
        final prompt = process.prompt;
        final sentAt = process.sentAt;
        if (entries?.any(
              (e) =>
                  e['uuid'] == prompt ||
                  (sentAt != null &&
                      DateTime.tryParse(
                            '${e['timestamp']}',
                          )?.isBefore(sentAt) ==
                          false),
            ) ??
            false) {
          process.cut = null;
          if (_rewinds?[chatId] == cut) {
            _rewinds!.remove(chatId);
            await _writeRewinds();
          }
        }
      }
      // Read once, as the process started, and the session keeps it (§11):
      // not left on disk with a copy of the user's memories.
      if (sessionFile != null) {
        try {
          await File(sessionFile).delete();
        } on FileSystemException catch (_) {}
      }
      // A tool-less turn's process has no next turn: it goes now.
      if (process.exited || toolless) {
        _live.remove(chatId);
        if (!process.exited) unawaited(process.kill());
      } else {
        process.idleAfter(_idleTimeout, () {
          if (_live[chatId] == process) _live.remove(chatId);
        });
      }
    }
  }

  /// The file a process for [chatId] appends to its system prompt: GAIA.md's
  /// own, or GAIA.md and [sessionInstructions] in the chat's; null for
  /// nothing to append.
  Future<String?> _instructionsFileFor(
    String chatId,
    String sessionInstructions,
  ) async {
    if (sessionInstructions.trim().isEmpty) {
      return _instructions.trim().isEmpty ? null : instructionsFile;
    }
    final file = File(
      p.join(p.dirname(instructionsFile), 'sessions', '$chatId.md'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      [
        _instructions.trim(),
        sessionInstructions.trim(),
      ].where((text) => text.isNotEmpty).join('\n\n'),
    );
    return file.path;
  }

  @override
  bool isRunning(String chatId) => _live[chatId]?.inTurn ?? false;

  /// Each config dir's commands, read once per companion run.
  final _nativeCommands = <String, Future<List<GaiaNativeCommand>>>{};

  @override
  Future<List<GaiaNativeCommand>> nativeCommands(GaiaAccount? account) {
    final configDir = account?.dir ?? '';
    return _nativeCommands[configDir] ??= _readNativeCommands(configDir)
        .catchError((Object error) {
          debugPrint('[gaia] Claude Code commands not read: $error');
          return const <GaiaNativeCommand>[];
        })
        .then((commands) {
          // Asked again next time: the CLI may not have been ready.
          if (commands.isEmpty) _nativeCommands.remove(configDir);
          return commands;
        });
  }

  /// The commands an `initialize` response lists (GAIA_NATIVE_COMMANDS.md
  /// §3), from a process started just to hear it and then killed. No message
  /// goes, so it makes no session (checked on 2.1.319). Safe mode lists only
  /// Claude Code's bundled commands and skills, not the user's own.
  Future<List<GaiaNativeCommand>> _readNativeCommands(String configDir) async {
    final sessionId = _uuid.v4();
    final _ClaudeProcess process;
    try {
      process = await _ClaudeProcess.start(
        workingDirectory: workingDirectory,
        // Any: no model is called.
        model: 'haiku',
        effort: null,
        configDir: configDir,
        onLine: null,
        directories: const {},
        sessionId: sessionId,
        cut: null,
        fork: null,
        toolless: false,
        sessionArgs: ['--session-id', sessionId],
      );
    } on ProcessException catch (error) {
      debugPrint('[gaia] Claude Code commands not read: $error');
      return const [];
    }
    try {
      final refused = await process.ready.timeout(
        const Duration(seconds: 30),
        onTimeout: () => 'no initialize response',
      );
      if (refused != null) {
        debugPrint('[gaia] Claude Code commands not read: $refused');
        return const [];
      }
      return [
        for (final command in process.commands ?? const <GaiaNativeCommand>[])
          if (!kClaudeBlockedCommands.containsKey(command.name)) command,
      ];
    } finally {
      await process.kill();
    }
  }

  /// GAIA.md changed. Processes between turns are let go, so each chat's
  /// next message resumes under the new text; one mid-turn finishes on the
  /// old.
  @override
  Future<void> setInstructions(String text) async {
    if (text == _instructions) return;
    _instructions = text;
    final file = File(instructionsFile);
    if (text.trim().isEmpty) {
      if (await file.exists()) await file.delete();
    } else {
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }
    _releaseIdle();
  }

  /// Claude Code keeps a session at `<config dir>/projects/<cwd slug>/<id>.jsonl`,
  /// with its subagents' and tools' files in `<id>/` beside it. The slug is
  /// taken from where the session is rather than worked out here. Resuming a
  /// copy on another login works, signed thinking included (checked both ways
  /// on 2.1.316).
  @override
  Future<bool> copySession({
    required String sessionId,
    required GaiaAccount from,
    required GaiaAccount to,
  }) async {
    final fromRoot = claudeConfigRoot(from.dir);
    final toRoot = claudeConfigRoot(to.dir);
    if (p.equals(fromRoot, toRoot)) return true;
    final projects = Directory(p.join(fromRoot, 'projects'));
    if (!await projects.exists()) return false;
    await for (final project in projects.list()) {
      final file = File(p.join(project.path, '$sessionId.jsonl'));
      if (!await file.exists()) continue;
      final target = p.join(toRoot, 'projects', p.basename(project.path));
      await Directory(target).create(recursive: true);
      await file.copy(p.join(target, '$sessionId.jsonl'));
      final extras = Directory(p.join(project.path, sessionId));
      if (await extras.exists()) {
        await for (final entry in extras.list(recursive: true)) {
          if (entry is! File) continue;
          final copy = File(
            p.join(
              target,
              sessionId,
              p.relative(entry.path, from: extras.path),
            ),
          );
          await copy.parent.create(recursive: true);
          await entry.copy(copy.path);
        }
      }
      return true;
    }
    return false;
  }

  void _releaseIdle() {
    for (final chatId in [..._live.keys]) {
      if (!_live[chatId]!.inTurn) unawaited(_live.remove(chatId)!.kill());
    }
  }

  /// Kills [chatId]'s process tree; its turn fails.
  @override
  Future<void> stop(String chatId) async {
    // Still starting, maybe after a process left from an earlier turn,
    // killed below: its own is stopped before the prompt goes.
    if (_starting.contains(chatId)) _stoppedStarting.add(chatId);
    final process = _live.remove(chatId);
    if (process == null) return;
    if (process.prompt case final prompt? when process.inTurn) {
      _stopped[chatId] = (
        sessionId: process.sessionId,
        prompt: prompt,
        sentAt: process.sentAt!,
        process: process,
      );
    }
    await process.kill();
  }

  @override
  void forgetStop(String chatId) {
    _stopped.remove(chatId);
    _stoppedStarting.remove(chatId);
  }

  /// Finds the stopped prompt in the session JSONL by the uuid Gaia gave it,
  /// then checks a resume cut to just before it starts cleanly: refused, or
  /// with flags it doesn't know, the CLI says so at once (checked on
  /// 2.1.318). The cut itself is made by the next turn's process.
  @override
  Future<String?> takeBack(String chatId) async {
    // Stopped before its prompt went: the session never had it.
    if (_stoppedStarting.remove(chatId)) return null;
    final turn = _stopped.remove(chatId);
    if (turn == null) return 'Claude Code was not running it.';
    final process = turn.process;
    final entries = await _sessionEntries(process.configDir, turn.sessionId);
    if (entries == null) return "Claude Code's session file wasn't found.";
    final prompt = entries.where((e) => e['uuid'] == turn.prompt).firstOrNull;
    if (prompt == null) {
      // Killed before it read the prompt: the session never had it.
      final later = entries.any(
        (e) =>
            DateTime.tryParse('${e['timestamp']}')?.isBefore(turn.sentAt) ==
            false,
      );
      return later
          ? 'Claude Code saved the message, but not under the id Gaia gave it.'
          : null;
    }
    final keepAt = prompt['parentUuid'];
    if (keepAt is! String) {
      return 'The message had nothing before it to go back to.';
    }
    final cut = (sessionId: turn.sessionId, keepAt: keepAt, drops: turn.prompt);
    final check = await _ClaudeProcess.start(
      workingDirectory: workingDirectory,
      model: process.model,
      effort: process.effort,
      configDir: process.configDir,
      onLine: onLine,
      directories: process.directories,
      sessionId: turn.sessionId,
      cut: cut,
      fork: null,
      toolless: false,
      sessionArgs: ['--resume', turn.sessionId, ...cut.args],
    );
    final refused = await check.ready.timeout(
      const Duration(seconds: 30),
      onTimeout: () => 'it never answered',
    );
    await check.kill();
    if (refused != null) {
      return "Claude Code wouldn't resume from before it: $refused";
    }
    (await _readRewinds())[chatId] = cut;
    await _writeRewinds();
    return null;
  }

  @override
  Future<void> rewound(String chatId, String forkId) async {
    if (_live[chatId] case final process? when !process.inTurn) {
      _live.remove(chatId);
      unawaited(process.kill());
    }
    final rewinds = await _readRewinds();
    if (rewinds.remove(chatId) case final cut?) {
      rewinds[forkId] = cut;
      await _writeRewinds();
    }
  }

  /// After the first turn on a process resumed with [cut]: its prompt's
  /// entry must hang off the kept one. Null when it does.
  String? _checkCut(
    _Rewind cut,
    _ClaudeProcess process,
    List<Map<String, Object?>>? entries,
  ) {
    final prompt = entries
        ?.where((e) => e['uuid'] == process.prompt)
        .firstOrNull;
    if (prompt?['parentUuid'] == cut.keepAt) return null;
    debugPrint(
      '[gaia] take-back did not hold: ${process.prompt} hangs off '
      '${prompt?['parentUuid']}, not ${cut.keepAt}',
    );
    return 'Claude Code may still remember the message you stopped earlier: '
        "the way Gaia takes one back (Claude Code's undocumented "
        '--resume-session-at) did not behave as expected.';
  }

  /// After a fork's first turn (GAIA_FORKING_HLD.md §5.3): its prompt's entry
  /// must hang off [fork]'s cut. Null when it does.
  String? _checkFork(
    GaiaForkCut fork,
    _ClaudeProcess process,
    List<Map<String, Object?>>? entries,
  ) {
    final prompt = entries
        ?.where((e) => e['uuid'] == process.prompt)
        .firstOrNull;
    if (prompt?['parentUuid'] == fork.keepAt) return null;
    debugPrint(
      '[gaia] fork did not hold: ${process.prompt} hangs off '
      '${prompt?['parentUuid']}, not ${fork.keepAt}',
    );
    return 'This fork may remember more of the chat it came from than it '
        "shows: the way Gaia forks a chat (Claude Code's undocumented "
        '--resume-session-at) did not behave as expected.';
  }

  @override
  Future<String?> forkCut({
    required String chatId,
    required String sessionId,
    required GaiaAccount account,
    required String after,
    required List<String> next,
    String? awaiting,
    String? endAt,
  }) async {
    // A prompt just sent can be a moment from the file (§5.2).
    final until = DateTime.now().add(_forkWait);
    var entries = await _sessionEntries(account.dir, sessionId);
    while (awaiting != null &&
        entries != null &&
        !entries.any((e) => e['uuid'] == awaiting)) {
      if (DateTime.now().isAfter(until)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      entries = await _sessionEntries(account.dir, sessionId);
    }
    if (entries == null) return null;
    final byUuid = {
      for (final entry in entries)
        if (entry['uuid'] case final String uuid) uuid: entry,
    };
    if (!byUuid.containsKey(after)) return null;
    for (final id in next) {
      if (byUuid[id] case final entry?) {
        return switch (entry['parentUuid']) {
          final String parent => parent,
          _ => null,
        };
      }
    }
    // Nothing after it: where the caller says the copies end, or the
    // session's end, unless a take-back's cut is still to be made, whose
    // dropped turn is the file's end.
    if (endAt != null) return endAt;
    if ((await _readRewinds())[chatId] case final cut?
        when cut.sessionId == sessionId) {
      return cut.keepAt;
    }
    return entries.lastWhereOrNull(
          (e) =>
              e['uuid'] is String &&
              (e['type'] == 'user' || e['type'] == 'assistant'),
        )?['uuid']
        as String?;
  }

  /// [sessionId]'s JSONL entries under [configDir], unreadable lines
  /// skipped; null when there's no such session, or it can't be read (held
  /// by the CLI, say).
  Future<List<Map<String, Object?>>?> _sessionEntries(
    String configDir,
    String sessionId,
  ) async {
    try {
      final projects = Directory(
        p.join(claudeConfigRoot(configDir), 'projects'),
      );
      if (!await projects.exists()) return null;
      await for (final project in projects.list()) {
        final file = File(p.join(project.path, '$sessionId.jsonl'));
        if (!await file.exists()) continue;
        // A line cut off mid-character by a kill is only that line's loss.
        final lines = await file.readAsLines(
          encoding: const Utf8Codec(allowMalformed: true),
        );
        return [for (final line in lines) ?_entry(line)];
      }
    } on FileSystemException catch (error) {
      debugPrint('[gaia] Claude Code session $sessionId unread: $error');
    }
    return null;
  }

  static Map<String, Object?>? _entry(String line) {
    try {
      final json = jsonDecode(line);
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, _Rewind>> _readRewinds() async {
    if (_rewinds case final rewinds?) return rewinds;
    final rewinds = <String, _Rewind>{};
    try {
      final json = jsonDecode(await _rewindsFile.readAsString());
      if (json is Map) {
        for (final MapEntry(:key, :value) in json.entries) {
          if (value case {
            'sessionId': final String sessionId,
            'keepAt': final String keepAt,
            'drops': final String drops,
          }) {
            rewinds['$key'] = (
              sessionId: sessionId,
              keepAt: keepAt,
              drops: drops,
            );
          }
        }
      }
    } on FileSystemException catch (_) {
    } on FormatException catch (_) {}
    return _rewinds ??= rewinds;
  }

  /// One write at a time, each of the map as it then is. A failed one leaves
  /// the turn's own result alone; the map in memory still holds.
  Future<void> _writeRewinds() => _writing = _writing.then((_) async {
    try {
      final file = _rewindsFile;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          for (final MapEntry(:key, :value) in _rewinds!.entries)
            key: {
              'sessionId': value.sessionId,
              'keepAt': value.keepAt,
              'drops': value.drops,
            },
        }),
      );
    } on FileSystemException catch (error) {
      debugPrint('[gaia] claude-rewinds.json not written: $error');
    }
  });

  /// Kills every process tree this runner started.
  @override
  Future<void> killAll() async {
    final processes = [..._live.values];
    _live.clear();
    await Future.wait([for (final process in processes) process.kill()]);
  }
}

class _ClaudeProcess {
  _ClaudeProcess._(
    this._process,
    this.model,
    this.effort,
    this.configDir,
    this.directories,
    this._onRawLine,
    this.sessionId,
    this.cut,
    this.fork,
  ) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _process.stderr.transform(utf8.decoder).listen((text) {
      _stderr.write(text);
      if (_stderr.length > 4096) {
        final tail = _stderr.toString();
        _stderr
          ..clear()
          ..write(tail.substring(tail.length - 2048));
      }
    });
    unawaited(
      _process.exitCode.then((code) {
        exited = true;
        _idle?.cancel();
        _fail(
          'Claude Code exited (code $code)'
          '${_stderr.isEmpty ? '' : ': ${_stderr.toString().trim()}'}',
        );
      }),
    );
  }

  static Future<_ClaudeProcess> start({
    required String workingDirectory,
    required String model,
    required String? effort,
    required String configDir,
    required void Function(String line)? onLine,
    required Set<String> directories,
    required String sessionId,
    required _Rewind? cut,
    required GaiaForkCut? fork,
    required bool toolless,
    required List<String> sessionArgs,
  }) async {
    await Directory(workingDirectory).create(recursive: true);
    // A file: through cmd, the JSON's quotes wouldn't survive as an
    // argument.
    final mcpConfig = p.join(workingDirectory, 'gaia-mcp.json');
    await File(mcpConfig).writeAsString(_mcpConfig);
    // Through cmd: an npm install's `claude` is a .cmd shim, which only a
    // shell can run.
    final process = _ClaudeProcess._(
      await Process.start(
        'cmd',
        [
          '/c',
          'claude',
          '-p',
          '--input-format',
          'stream-json',
          '--output-format',
          'stream-json',
          '--verbose',
          '--include-partial-messages',
          '--safe-mode',
          // None of Gaia's, nor the CLI's own (GAIA_BTW_HLD.md §6): an empty
          // list, which `init` then lists none of (checked on 2.1.319).
          if (toolless) ...[
            '--tools',
            '',
          ] else ...[
            '--mcp-config',
            mcpConfig,
            '--permission-prompt-tool',
            'stdio',
            '--disallowedTools',
            'AskUserQuestion',
          ],
          '--model',
          model,
          if (effort != null) ...['--effort', effort],
          // Outside the workspace, where attached files are read (§9.3).
          for (final directory in directories) ...['--add-dir', directory],
          ...sessionArgs,
        ],
        workingDirectory: workingDirectory,
        environment: {
          ...claudeEnvironment(configDir),
          'MCP_TOOL_TIMEOUT': '${kGaiaMcpToolTimeout.inMilliseconds}',
        },
        includeParentEnvironment: false,
      ),
      model,
      effort,
      configDir,
      directories,
      onLine,
      sessionId,
      cut,
      fork,
    );
    // Registers the `sdk` server the config names; the CLI then lists its
    // tools through [_answer].
    process._write({
      'type': 'control_request',
      'request_id': 'gaia_initialize',
      'request': {'subtype': 'initialize'},
    });
    return process;
  }

  final Process _process;
  final String model;
  final String? effort;
  final String configDir;
  final Set<String> directories;
  final void Function(String line)? _onRawLine;
  final _stderr = StringBuffer();
  var exited = false;

  /// The session it started or resumed; a fork's, once its `init` names it.
  String sessionId;

  /// The take-back it resumed with, until a turn on it has started.
  _Rewind? cut;

  /// The session it forked (GAIA_FORKING_HLD.md §5.3), or null.
  final GaiaForkCut? fork;

  /// [kill] was called.
  var killed = false;

  /// The uuid the current or last turn's prompt went with, and when.
  String? prompt;
  DateTime? sentAt;

  final _ready = Completer<String?>();

  /// Null once the CLI answered `initialize`, else why it didn't: what it
  /// printed on stderr as it refused or ended.
  Future<String?> get ready => _ready.future;

  void _settle(String reason) {
    if (_ready.isCompleted) return;
    _ready.complete(_stderr.isEmpty ? reason : _stderr.toString().trim());
  }

  /// An `init` came: the CLI started or resumed a session. Once a process.
  var started = false;

  /// The `/` commands its `initialize` response listed; null before it.
  List<GaiaNativeCommand>? commands;

  /// The model `init` named: [model] resolved, as `modelUsage` keys it.
  String? sessionModel;
  Timer? _idle;

  void Function(ClaudeEvent event)? _onEvent;
  GaiaTurnTools? _tools;
  Completer<ClaudeResult>? _turn;

  bool get inTurn => _turn != null;

  /// [content] is text, or content blocks ([claudeUserContent]). [promptId]
  /// is the uuid it goes with; null for a random one.
  Future<ClaudeResult> turn(
    Object content,
    GaiaTurnTools? tools,
    void Function(ClaudeEvent event) onEvent, [
    String? promptId,
  ]) {
    _idle?.cancel();
    final turn = _turn = Completer<ClaudeResult>();
    _onEvent = onEvent;
    _tools = tools;
    // The id its JSONL entry gets, for a take-back to find it by, and a fork
    // to cut at (GAIA_FORKING_HLD.md §5.1): the message's own, when given.
    final uuid = prompt = promptId ?? _uuid.v4();
    sentAt = DateTime.now();
    _write({
      'type': 'user',
      'uuid': uuid,
      'message': {'role': 'user', 'content': content},
    });
    return turn.future;
  }

  void _write(Map<String, Object?> message) {
    if (!exited) _process.stdin.writeln(jsonEncode(message));
  }

  /// A `control_request`: an MCP message for Gaia's tools, or a permission
  /// prompt, answered by the turn's tools. Between turns only the MCP
  /// handshake comes, which needs none.
  Future<void> _answer(ClaudeControlRequest request) async {
    final tools = _tools;
    final Map<String, Object?> response;
    switch (request.subtype) {
      case 'mcp_message':
        final message = request.request['message'];
        if (request.request['server_name'] != kGaiaMcpServer ||
            message is! Map) {
          return _refuse(request, 'unknown MCP server');
        }
        response = {
          'mcp_response':
              await gaiaMcpAnswer(message.cast<String, Object?>(), tools) ??
              // A notification: acknowledged, as the CLI waits on each.
              {'jsonrpc': '2.0', 'result': <String, Object?>{}},
        };
      case 'can_use_tool':
        final input =
            (request.request['input'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
        final decision = tools == null
            ? (allow: false, message: 'No Gaia run is active.')
            : await tools.permit(
                tool: request.request['tool_name'] as String? ?? '',
                input: input,
                description: request.request['description'] as String? ?? '',
              );
        response = decision.allow
            ? {'behavior': 'allow', 'updatedInput': input}
            : {
                'behavior': 'deny',
                'message': decision.message.isEmpty
                    ? 'The user declined.'
                    : decision.message,
              };
      default:
        return _refuse(request, 'unsupported request ${request.subtype}');
    }
    _write({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': request.requestId,
        'response': response,
      },
    });
  }

  void _refuse(ClaudeControlRequest request, String error) => _write({
    'type': 'control_response',
    'response': {
      'subtype': 'error',
      'request_id': request.requestId,
      'error': error,
    },
  });

  void idleAfter(Duration timeout, void Function() onKilled) {
    _idle?.cancel();
    _idle = Timer(timeout, () {
      onKilled();
      unawaited(kill());
    });
  }

  void _onLine(String line) {
    _onRawLine?.call(line);
    if (line.trim().isEmpty) return;
    final ClaudeEvent event;
    try {
      event = parseClaudeLine(line);
    } on ClaudeParseException catch (error) {
      debugPrint('[gaia] $error');
      _fail('Unreadable output from Claude Code: ${error.reason}');
      unawaited(kill());
      return;
    }
    if (event is ClaudeInit) {
      started = true;
      sessionModel = event.model;
      if (fork != null) sessionId = event.sessionId;
    }
    if (event case final ClaudeControlRequest request) {
      // Always answered: the CLI blocks on the request until it is.
      unawaited(
        _answer(request).catchError((Object error) {
          debugPrint('[gaia] control_request failed: $error');
          _refuse(request, '$error');
        }),
      );
    }
    if (event case ClaudeControlResponse(:final error?)) {
      debugPrint("[gaia] Claude Code refused Gaia's tools: $error");
    }
    if (event case ClaudeControlResponse(
      requestId: 'gaia_initialize',
      :final error,
    )) {
      if (event case ClaudeControlResponse(:final commands?)) {
        this.commands = commands;
      }
      if (error == null && !_ready.isCompleted) _ready.complete(null);
      if (error != null) _settle(error);
    }
    // A result before any turn: the resume was refused.
    if (event case ClaudeResult(:final text) when _turn == null) {
      _settle(text.isEmpty ? 'it ended the session' : text);
    }
    // Between turns there's nothing to report to.
    _onEvent?.call(event);
    if (event is ClaudeResult) {
      final turn = _turn;
      _turn = null;
      _onEvent = null;
      _tools = null;
      turn?.complete(event);
    }
  }

  void _fail(String reason) {
    _settle(reason);
    final turn = _turn;
    _turn = null;
    _onEvent = null;
    _tools = null;
    turn?.completeError(GaiaRunException(reason));
  }

  /// Kills the whole tree: cmd, the CLI, and anything the CLI started.
  Future<void> kill() async {
    _idle?.cancel();
    killed = true;
    if (exited) return;
    await Process.run('taskkill', ['/t', '/f', '/pid', '${_process.pid}']);
  }
}

/// `claude --version`, parsed; null when the CLI isn't installed or its
/// output isn't a version.
Future<(int, int, int)?> claudeCodeVersion() async {
  try {
    final result = await Process.run('cmd', ['/c', 'claude', '--version']);
    if (result.exitCode != 0) return null;
    return parseClaudeVersion(result.stdout as String);
  } on ProcessException {
    return null;
  }
}

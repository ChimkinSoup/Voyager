// FRAGILE(cli): the Claude Code invocation and its stdin message shape
// (`--input-format stream-json`). See claude_code_events.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

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

/// A user message's `content` (§9.3): [prompt] alone, or with [images] as
/// content blocks interleaved where their `[image N]` tokens are, each after
/// the text that ends in its token. An image whose token isn't in [prompt]
/// goes at the end, after its token.
@visibleForTesting
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
const _maxLive = 4;

/// Runs chats on the Claude Code CLI: one long-lived process per active chat,
/// whose stdin stays open across turns. A process idle for 10 minutes is
/// killed and the next message resumes its session; past four live, the
/// least recently used goes. The model is pinned per process (§5.1): a turn
/// on another model restarts the process, resuming the same session (§7.4).
///
/// Every process runs in safe mode, which leaves out the user's global
/// CLAUDE.md, hooks and plugins (§5.2: `--setting-sources` doesn't keep
/// CLAUDE.md out, checked on 2.1.310), with GAIA.md appended to the system
/// prompt from [instructionsFile].
class ClaudeCodeRunner implements GaiaAgentRunner {
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

  /// The account's `CLAUDE_CONFIG_DIR` (§6.1); empty for Voyager's own.
  var _configDir = '';

  /// Every line the CLI prints, before it's parsed: for the CLI contract
  /// check (`qa/harness/gaia_cli_check.ps1`).
  final void Function(String line)? onLine;

  /// Live processes by chat id, least recently used first.
  final _live = <String, _ClaudeProcess>{};

  @override
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String prompt,
    List<GaiaImageInput> images = const [],
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    final (result, started) = await _send(
      chatId: chatId,
      sessionId: sessionId,
      newSessionId: sessionId ?? _uuid.v4(),
      model: model,
      prompt: prompt,
      images: images,
      onEvent: (event) {
        if (gaiaEventOf(event) case final event?) onEvent(event);
      },
    );
    return GaiaTurnResult(
      sessionId: result.sessionId,
      isError: result.isError,
      text: result.text,
      contextTokens: result.contextTokens,
      sessionFound: started,
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
    required void Function(ClaudeEvent event) onEvent,
  }) async => (await _send(
    chatId: chatId,
    sessionId: sessionId,
    newSessionId: newSessionId,
    model: model,
    prompt: prompt,
    images: images,
    onEvent: onEvent,
  )).$1;

  /// [sendRaw], and whether the process got as far as a session: a resume
  /// that finds none ends in an error result without an `init`.
  Future<(ClaudeResult, bool)> _send({
    required String chatId,
    required String? sessionId,
    required String newSessionId,
    required String model,
    required String prompt,
    required List<GaiaImageInput> images,
    required void Function(ClaudeEvent event) onEvent,
  }) async {
    final content = await claudeUserContent(prompt, images);
    var process = _live.remove(chatId);
    // One that never started a session (a resume that found none) is on
    // its way out.
    if (process != null && (process.model != model || !process.started)) {
      unawaited(process.kill());
      process = null;
    }
    if (process == null || process.exited) {
      // Never one mid-turn: past four running at once, there are just more.
      while (_live.length >= _maxLive) {
        final idle = _live.keys.where((id) => !_live[id]!.inTurn).firstOrNull;
        if (idle == null) break;
        unawaited(_live.remove(idle)!.kill());
      }
      process = await _ClaudeProcess.start(
        workingDirectory: workingDirectory,
        model: model,
        configDir: _configDir,
        onLine: onLine,
        sessionArgs: [
          if (_instructions.trim().isNotEmpty) ...[
            '--append-system-prompt-file',
            instructionsFile,
          ],
          ...sessionId == null
              ? ['--session-id', newSessionId]
              : ['--resume', sessionId],
        ],
      );
    }
    _live[chatId] = process;
    try {
      return (await process.turn(content, onEvent), process.started);
    } finally {
      if (process.exited) {
        _live.remove(chatId);
      } else {
        process.idleAfter(_idleTimeout, () {
          if (_live[chatId] == process) _live.remove(chatId);
        });
      }
    }
  }

  @override
  bool isRunning(String chatId) => _live[chatId]?.inTurn ?? false;

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

  /// Another account (§6.1): as for GAIA.md, processes between turns are
  /// let go. A chat started on the old one can't be resumed on the new.
  void setConfigDir(String dir) {
    if (dir == _configDir) return;
    _configDir = dir;
    _releaseIdle();
  }

  void _releaseIdle() {
    for (final chatId in [..._live.keys]) {
      if (!_live[chatId]!.inTurn) unawaited(_live.remove(chatId)!.kill());
    }
  }

  /// Kills [chatId]'s process tree; its turn fails.
  @override
  Future<void> stop(String chatId) async => _live.remove(chatId)?.kill();

  /// Kills every process tree this runner started.
  @override
  Future<void> killAll() async {
    final processes = [..._live.values];
    _live.clear();
    await Future.wait([for (final process in processes) process.kill()]);
  }
}

class _ClaudeProcess {
  _ClaudeProcess._(this._process, this.model, this._onRawLine) {
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
    required String configDir,
    required void Function(String line)? onLine,
    required List<String> sessionArgs,
  }) async {
    await Directory(workingDirectory).create(recursive: true);
    // Through cmd: an npm install's `claude` is a .cmd shim, which only a
    // shell can run.
    return _ClaudeProcess._(
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
          '--model',
          model,
          ...sessionArgs,
        ],
        workingDirectory: workingDirectory,
        environment: claudeEnvironment(configDir),
        includeParentEnvironment: false,
      ),
      model,
      onLine,
    );
  }

  final Process _process;
  final String model;
  final void Function(String line)? _onRawLine;
  final _stderr = StringBuffer();
  var exited = false;

  /// An `init` came: the CLI started or resumed a session. Once a process.
  var started = false;
  Timer? _idle;

  void Function(ClaudeEvent event)? _onEvent;
  Completer<ClaudeResult>? _turn;

  bool get inTurn => _turn != null;

  /// [content] is text, or content blocks ([claudeUserContent]).
  Future<ClaudeResult> turn(
    Object content,
    void Function(ClaudeEvent event) onEvent,
  ) {
    _idle?.cancel();
    final turn = _turn = Completer<ClaudeResult>();
    _onEvent = onEvent;
    _process.stdin.writeln(
      jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': content},
      }),
    );
    return turn.future;
  }

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
    if (event is ClaudeInit) started = true;
    // Between turns there's nothing to report to.
    _onEvent?.call(event);
    if (event is ClaudeResult) {
      final turn = _turn;
      _turn = null;
      _onEvent = null;
      turn?.complete(event);
    }
  }

  void _fail(String reason) {
    final turn = _turn;
    _turn = null;
    _onEvent = null;
    turn?.completeError(GaiaRunException(reason));
  }

  /// Kills the whole tree: cmd, the CLI, and anything the CLI started.
  Future<void> kill() async {
    _idle?.cancel();
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

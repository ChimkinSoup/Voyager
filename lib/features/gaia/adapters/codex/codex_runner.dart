// FRAGILE(cli): the Codex invocation (`codex exec --json`, `codex exec resume`)
// and the layout of a Codex home (`auth.json`, `AGENTS.md`, `config.toml`'s
// `[windows] sandbox`, and `.sandbox/setup_marker.json`, which Codex writes
// once the elevated Windows sandbox is set up for that home; observed on
// 0.164.0), and the `mcp_servers` keys that start Gaia's MCP shim
// (`tool_timeout_sec`, `default_tools_approval_mode`; observed on 0.164.0).
// See codex_events.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/platform/dev_profile.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/tools/gaia_tool_pipe.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// Keys stripped from the CLI's environment, so a stray API key never moves
/// a ChatGPT login onto API billing.
const _strippedEnvironment = {'OPENAI_API_KEY', 'CODEX_API_KEY'};

/// Runs chats on the Codex CLI (GAIA_HLD.md §5.1). `codex exec` can't keep
/// stdin open across turns, so each turn is its own process: a new thread,
/// or `codex exec resume` on the chat's.
///
/// Every process runs with [codexHome], Gaia's own Codex home (§5.2), so
/// GAIA.md stands in for the user's global AGENTS.md and none of their
/// config, hooks or skills load. The login is the user's: `auth.json` is
/// copied from [userCodexHome] whenever theirs is newer, which also picks up
/// a re-login. The one setting carried over is the Windows sandbox, without
/// which every shell command is refused.
///
/// Gaia's tools reach Codex through [toolPipe] (§5.3): each turn's process
/// starts `voyager.exe --gaia-mcp` as an MCP server, its calls approved
/// up front (Codex would otherwise refuse them under `exec`'s "never"
/// approval policy) and its timeout set past [kGaiaCardHold].
///
/// An elevated sandbox has to be set up once per Codex home, behind a
/// Windows approval prompt. A headless run that hit it would hang on a
/// prompt nobody asked for, so until [setUpCodexSandbox] has run (the Gaia
/// page's Setup tab) a turn fails at once, saying so.
class CodexRunner implements GaiaAgentRunner {
  CodexRunner({
    required this.workingDirectory,
    required this.codexHome,
    String? userCodexHome,
    this.toolPipe,
    String? executable,
    this.onLine,
  }) : userCodexHome = userCodexHome ?? defaultUserCodexHome(),
       executable = executable ?? Platform.resolvedExecutable;

  final String workingDirectory;
  final String codexHome;
  final String userCodexHome;

  /// Where the shims connect; null offers Codex no Gaia tools.
  final GaiaToolPipe? toolPipe;

  /// voyager.exe, which `--gaia-mcp` makes the shim.
  final String executable;

  /// Every line the CLI prints, before it's parsed.
  final void Function(String line)? onLine;

  final _live = <String, _CodexProcess>{};

  @override
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String prompt,
    List<GaiaImageInput> images = const [],
    // Its sandboxes read anywhere: `--add-dir` is for writing.
    Set<String> directories = const {},
    GaiaTurnTools? tools,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    final (:notReady, :sandbox) = await readyCodexHome(
      codexHome,
      userCodexHome,
    );
    if (notReady != null) return notReady;
    final pipe = toolPipe;
    final serveTools = tools != null && pipe != null && await pipe.listen();
    const server = 'mcp_servers.$kGaiaMcpServer';
    final process = _live[chatId] = await _CodexProcess.start(
      workingDirectory: workingDirectory,
      codexHome: codexHome,
      onLine: onLine,
      args: [
        'exec',
        if (sessionId != null) 'resume',
        '--json',
        '--skip-git-repo-check',
        '-m',
        model,
        if (sandbox != null) ...['-c', 'windows.sandbox=$sandbox'],
        // TOML literal strings: a path's backslashes stay as they are. The
        // path's is multi-line, which may hold an apostrophe.
        if (serveTools) ...[
          '-c',
          "$server.command='''$executable'''",
          '-c',
          "$server.args=['--gaia-mcp']",
          '-c',
          '$server.tool_timeout_sec=${kGaiaMcpToolTimeout.inSeconds}',
          '-c',
          "$server.default_tools_approval_mode='approve'",
          // Codex starts MCP servers with only a few environment variables:
          // the shim needs the dev profile to find this companion's pipe.
          if (devProfile case final profile?) ...[
            '-c',
            "$server.env={VOYAGER_PROFILE='$profile'}",
          ],
        ],
        // Attached apart from the text, which keeps their `[image N]`
        // labels (§9.3). One value per flag: `--image a b` would take the
        // `-` below as an image too.
        for (final image in images) '--image=${image.path}',
        ?sessionId,
        // The prompt comes on stdin: `cmd /c` would mangle it as an argument.
        '-',
      ],
    );
    final unbind = serveTools ? pipe.bind(process.pid, tools) : null;
    try {
      return await process.turn(codexPrompt(prompt, images), onEvent);
    } finally {
      unbind?.call();
      if (_live[chatId] == process) _live.remove(chatId);
    }
  }

  @override
  bool isRunning(String chatId) => _live.containsKey(chatId);

  /// GAIA.md becomes Gaia's Codex home's AGENTS.md; the next turn reads it.
  @override
  Future<void> setInstructions(String text) async {
    final file = File(p.join(codexHome, 'AGENTS.md'));
    if (text.trim().isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  @override
  Future<void> stop(String chatId) async => _live.remove(chatId)?.kill();

  @override
  Future<void> killAll() async {
    final processes = [..._live.values];
    _live.clear();
    await Future.wait([for (final process in processes) process.kill()]);
  }
}

const kCodexSandboxNotSetUp =
    "Codex's sandbox isn't set up for Gaia yet. Set it up on the Gaia page's "
    'Setup tab.';

/// The user's own Codex home: `CODEX_HOME`, or `~/.codex`.
String defaultUserCodexHome() =>
    Platform.environment['CODEX_HOME'] ??
    p.join(Platform.environment['USERPROFILE'] ?? '', '.codex');

/// Gaia's own Codex home (§5.2). One per account from Phase 7.
Future<String> defaultGaiaCodexHome() async =>
    p.join((await appSupportRoot()).path, 'gaia', 'codex', 'default');

/// Readies Gaia's Codex home for a turn: the user's login copied in, and the
/// user's Windows sandbox, if any, to run it under. [notReady] is the turn's
/// result when that sandbox isn't set up for Gaia yet.
Future<({GaiaTurnResult? notReady, String? sandbox})> readyCodexHome(
  String codexHome,
  String userCodexHome,
) async {
  await _prepareCodexHome(codexHome, userCodexHome);
  final sandbox = await _windowsSandbox(userCodexHome);
  if (sandbox != null && !await _sandboxSetUp(codexHome)) {
    return (
      notReady: const GaiaTurnResult(
        sessionId: '',
        isError: true,
        text: kCodexSandboxNotSetUp,
      ),
      sandbox: sandbox,
    );
  }
  return (notReady: null, sandbox: sandbox);
}

/// A turn's prompt, naming its images' labels in order.
String codexPrompt(String prompt, List<GaiaImageInput> images) => images.isEmpty
    ? prompt
    // Nothing else says which attachment a label means.
    : '$prompt\n\n(Attached images, in order: '
          '${images.map((image) => gaiaImageToken(image.label)).join(', ')}.)';

/// Copies the user's login in when it's newer than Gaia's copy.
Future<void> _prepareCodexHome(String codexHome, String userCodexHome) async {
  await Directory(codexHome).create(recursive: true);
  final source = File(p.join(userCodexHome, 'auth.json'));
  final copy = File(p.join(codexHome, 'auth.json'));
  if (!await source.exists()) return;
  if (await copy.exists() &&
      !(await source.lastModified()).isAfter(await copy.lastModified())) {
    return;
  }
  await source.copy(copy.path);
}

/// `[windows] sandbox` from the user's config.toml, if they set one.
Future<String?> _windowsSandbox(String userCodexHome) async {
  final config = File(p.join(userCodexHome, 'config.toml'));
  if (!await config.exists()) return null;
  return parseCodexWindowsSandbox(await config.readAsString());
}

Future<bool> _sandboxSetUp(String codexHome) =>
    File(p.join(codexHome, '.sandbox', 'setup_marker.json')).exists();

/// Whether Gaia's Codex home needs no sandbox setup: the user runs Codex
/// without one, or it's done.
Future<bool> codexSandboxReady({
  required String codexHome,
  String? userCodexHome,
}) async =>
    await _windowsSandbox(userCodexHome ?? defaultUserCodexHome()) == null ||
    await _sandboxSetUp(codexHome);

/// Sets up the Windows sandbox for Gaia's Codex home by running one trivial
/// command in it: Windows shows its approval prompt now, while the user is
/// looking, rather than in the middle of a chat. True once it's set up.
Future<bool> setUpCodexSandbox({
  required String codexHome,
  String? userCodexHome,
}) async {
  final userHome = userCodexHome ?? defaultUserCodexHome();
  final sandbox = await _windowsSandbox(userHome);
  if (sandbox == null) return true;
  await _prepareCodexHome(codexHome, userHome);
  try {
    await Process.run(
      'cmd',
      [
        '/c',
        'codex',
        'sandbox',
        '-c',
        'windows.sandbox=$sandbox',
        'cmd',
        '/c',
        'echo',
        'gaia-sandbox-ok',
      ],
      environment: {'CODEX_HOME': codexHome},
    );
  } on ProcessException {
    return false;
  }
  return _sandboxSetUp(codexHome);
}

/// The `sandbox` key of a config.toml's `[windows]` table.
@visibleForTesting
String? parseCodexWindowsSandbox(String toml) {
  String? table;
  for (final raw in const LineSplitter().convert(toml)) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      table = line;
      continue;
    }
    if (table != '[windows]') continue;
    final match = RegExp(r'^sandbox\s*=\s*"([^"]*)"').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// A `codex` process in Gaia's Codex home, its output one line at a time.
/// [onLine] takes each line that isn't blank; a [CodexParseException] from
/// it kills the process. [onFail] is told when the output can't be read or
/// the process exits, with the last line of its stderr.
class CodexProcess {
  CodexProcess._(this._process, this._onRawLine, this._onLine, this._onFail) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line);
    _process.stderr.transform(utf8.decoder).listen((text) {
      _stderr.write(text);
      if (_stderr.length > 4096) {
        final tail = _stderr.toString();
        _stderr
          ..clear()
          ..write(tail.substring(tail.length - 2048));
      }
    });
    // A write after Codex died fails here; its exit fails the turn.
    _process.stdin.done.ignore();
    unawaited(
      _process.exitCode.then((code) {
        _exited = true;
        _onFail(
          'Codex exited (code $code)'
          '${_stderr.isEmpty ? '' : ': ${_lastLine(_stderr.toString())}'}',
        );
      }),
    );
  }

  static Future<CodexProcess> start({
    required String workingDirectory,
    required String codexHome,
    required List<String> args,
    required void Function(String line)? onRawLine,
    required void Function(String line) onLine,
    required void Function(String reason) onFail,
  }) async {
    await Directory(workingDirectory).create(recursive: true);
    final environment = {
      for (final entry in Platform.environment.entries)
        if (!_strippedEnvironment.contains(entry.key.toUpperCase()) &&
            entry.key.toUpperCase() != 'CODEX_HOME')
          entry.key: entry.value,
      'CODEX_HOME': codexHome,
    };
    // Through cmd: an npm install's `codex` is a .cmd shim, which only a
    // shell can run.
    return CodexProcess._(
      await Process.start(
        'cmd',
        ['/c', 'codex', ...args],
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: false,
      ),
      onRawLine,
      onLine,
      onFail,
    );
  }

  final Process _process;
  final void Function(String line)? _onRawLine;
  final void Function(String line) _onLine;
  final void Function(String reason) _onFail;
  final _stderr = StringBuffer();
  var _exited = false;
  var _killed = false;

  /// The cmd Gaia started, above Codex and anything it starts.
  int get pid => _process.pid;

  IOSink get stdin => _process.stdin;

  /// Also once it's being killed: nothing new should go to it.
  bool get exited => _exited || _killed;

  void _line(String line) {
    _onRawLine?.call(line);
    if (line.trim().isEmpty) return;
    try {
      _onLine(line);
    } on CodexParseException catch (error) {
      debugPrint('[gaia] $error');
      _onFail('Unreadable output from Codex: ${error.reason}');
      unawaited(kill());
    }
  }

  static String _lastLine(String text) =>
      const LineSplitter().convert(text.trim()).lastOrNull ?? '';

  /// Kills the whole tree: cmd, the CLI, and anything the CLI started.
  Future<void> kill() async {
    if (_exited) return;
    _killed = true;
    await Process.run('taskkill', ['/t', '/f', '/pid', '${_process.pid}']);
  }
}

/// One `codex exec` turn's process.
class _CodexProcess {
  _CodexProcess._();

  static Future<_CodexProcess> start({
    required String workingDirectory,
    required String codexHome,
    required void Function(String line)? onLine,
    required List<String> args,
  }) async {
    final codex = _CodexProcess._();
    codex._process = await CodexProcess.start(
      workingDirectory: workingDirectory,
      codexHome: codexHome,
      args: args,
      onRawLine: onLine,
      onLine: codex._onLine,
      onFail: codex._fail,
    );
    return codex;
  }

  late final CodexProcess _process;

  /// The cmd Gaia started, above Codex and the shims it starts.
  int get pid => _process.pid;

  void Function(GaiaAgentEvent event)? _onEvent;
  Completer<GaiaTurnResult>? _turn;
  String? _threadId;
  var _lastText = '';

  Future<GaiaTurnResult> turn(
    String prompt,
    void Function(GaiaAgentEvent event) onEvent,
  ) {
    final turn = _turn = Completer<GaiaTurnResult>();
    _onEvent = onEvent;
    _process.stdin.add(utf8.encode(prompt));
    unawaited(_process.stdin.close());
    return turn.future;
  }

  void _onLine(String line) {
    final event = parseCodexLine(line);
    switch (event) {
      case CodexThreadStarted(:final threadId):
        _threadId = threadId;
      case CodexMessage(:final text):
        _lastText = text;
      case CodexTurnEnded(:final error):
        final turn = _turn;
        final threadId = _threadId;
        _turn = null;
        if (turn == null) return;
        if (threadId == null) {
          turn.completeError(GaiaRunException('Codex never started a thread'));
          return;
        }
        turn.complete(
          GaiaTurnResult(
            sessionId: threadId,
            isError: error != null,
            text: error ?? _lastText,
          ),
        );
        return;
      case CodexTool() || CodexIgnored():
        break;
    }
    gaiaEventsOf(event).forEach(_onEvent ?? (_) {});
  }

  void _fail(String reason) {
    final turn = _turn;
    _turn = null;
    turn?.completeError(GaiaRunException(reason));
  }

  Future<void> kill() => _process.kill();
}

/// `codex --version`, parsed; null when the CLI isn't installed or its
/// output isn't a version.
Future<GaiaCliVersion?> codexVersion() async {
  try {
    final result = await Process.run('cmd', ['/c', 'codex', '--version']);
    if (result.exitCode != 0) return null;
    return parseCliVersion(result.stdout as String);
  } on ProcessException {
    return null;
  }
}

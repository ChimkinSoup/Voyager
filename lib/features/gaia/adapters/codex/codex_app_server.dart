// FRAGILE(cli): Codex's `codex app-server` JSON-RPC protocol, still marked
// experimental (observed on 0.164.0; `codex app-server generate-json-schema
// --experimental` prints it). Every shape read here has a recorded fixture
// under test/fixtures/gaia/codex_app_server/, which
// gaia_codex_app_server_test.dart replays. Re-record them, and move
// [kCodexTestedVersions], when a new CLI version is tested.
//
// What Gaia sends, one JSON object a line:
//   initialize {clientInfo, capabilities: {experimentalApi: true}}, then
//   the `initialized` notification; `experimentalApi` is what lets
//   thread/start take `dynamicTools`
//   thread/start {model, approvalPolicy: "on-request", dynamicTools}
//     -> {thread: {id}}; a thread keeps its tools when it's resumed
//   thread/resume {threadId, model, approvalPolicy} -> an error when there's
//     no such thread ("no rollout found for thread id …")
//   turn/start {threadId, model, input: [text | localImage]} -> {turn: {id}}
//   turn/interrupt {threadId, turnId}
// What it reads:
//   item/started, item/completed {threadId, item: {id, type, …}}: types
//     agentMessage {text}, commandExecution, fileChange {changes: [{path,
//     diff}]}, dynamicToolCall {tool}, reasoning, userMessage and others
//   item/agentMessage/delta {threadId, delta}: the reply streams
//   thread/tokenUsage/updated {threadId, tokenUsage: {last: {totalTokens}}}
//   error {threadId, error: {message}, willRetry}
//   turn/completed {threadId, turn: {status: completed | failed |
//     interrupted, error: {message}?}}
// What it answers (server requests, by their JSON-RPC id):
//   item/tool/call {threadId, tool, arguments} -> {contentItems: [{type:
//     "inputText", text}], success}
//   item/commandExecution/requestApproval {threadId, command, cwd, reason}
//   and item/fileChange/requestApproval {threadId, itemId, reason} ->
//     {decision: "accept" | "decline"}
//   item/permissions/requestApproval {threadId, permissions, cwd, reason} ->
//     {permissions: <granted>, scope: "turn"}
// Anything else it asks is refused with a JSON-RPC error.
//
// Strict: a message Gaia reads missing a field it reads is a parse failure,
// which fails every turn on the process and logs the raw line. Methods not
// read here are ignored.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// Gaia's tools as Codex's client-hosted tools (§5.3).
final _dynamicTools = [
  for (final tool in kGaiaToolDefinitions)
    {
      'type': 'function',
      'name': tool['name'],
      'description': tool['description'],
      'inputSchema': tool['inputSchema'],
    },
];

/// Which set of Gaia's tools a thread was started with: a thread keeps the
/// ones it started with, so one from before they changed is handed over to
/// a new thread instead.
final kCodexToolsHash = sha256
    .convert(utf8.encode(jsonEncode(_dynamicTools)))
    .toString()
    .substring(0, 16);

/// What an item type shows as in an activity part. Types not listed show as
/// themselves; a client-hosted tool shows as its name.
const _toolNames = {
  'commandExecution': 'Shell',
  'fileChange': 'Edit',
  'webSearch': 'WebSearch',
  'mcpToolCall': 'MCP',
  'imageView': 'ViewImage',
};

/// Item types that aren't the agent acting.
const _notTools = {
  'userMessage',
  'agentMessage',
  'reasoning',
  'plan',
  'contextCompaction',
  'hookPrompt',
};

class _RpcError implements Exception {
  _RpcError(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Turn {
  _Turn(this.tools, this.onEvent);

  final GaiaTurnTools? tools;
  final void Function(GaiaAgentEvent event) onEvent;
  final done = Completer<GaiaTurnResult>();
  String? turnId;
  int? contextTokens;
  String? error;
  var lastText = '';

  /// A message's trailing whitespace, held back until more text follows: a
  /// block shouldn't end in a blank line.
  var held = '';
}

/// One `codex app-server` process's side of the protocol: turns on its
/// threads, each answered by its turn's [GaiaTurnTools]. [onLine] takes
/// each line the server prints; what the client sends goes to [write].
class CodexAppServerClient {
  CodexAppServerClient(this._write);

  final void Function(String line) _write;

  var _nextId = 1;
  final _pending = <int, Completer<Map<String, Object?>>>{};

  /// Each running turn, by its thread.
  final _turns = <String, _Turn>{};

  /// Threads this process has started or resumed.
  final _loaded = <String>{};

  /// File changes in progress, by item id: their approvals name only the
  /// item.
  final _changes = <String, List<Object?>>{};

  bool get busy => _turns.isNotEmpty;

  Future<void> initialize() async {
    await _request('initialize', {
      'clientInfo': {'name': 'gaia', 'title': 'Gaia', 'version': '1'},
      'capabilities': {'experimentalApi': true},
    });
    _send({'method': 'initialized'});
  }

  /// A turn on [threadId], resumed if this process hasn't loaded it, or on
  /// a new thread, which [onNewThread] is told of. [onThread] is told the
  /// turn's thread once [stop] can reach it. A resume that finds no thread
  /// ends with `sessionFound: false`; one that fails otherwise, with an
  /// error that keeps it.
  Future<GaiaTurnResult> send({
    required String? threadId,
    required String model,
    required List<Map<String, Object?>> input,
    required GaiaTurnTools? tools,
    required void Function(GaiaAgentEvent event) onEvent,
    void Function(String threadId)? onThread,
    Future<void> Function(String threadId)? onNewThread,
  }) async {
    final String thread;
    if (threadId == null) {
      final Map<String, Object?> started;
      try {
        started = await _request('thread/start', {
          'model': model,
          'approvalPolicy': 'on-request',
          'dynamicTools': _dynamicTools,
        });
      } on _RpcError catch (error) {
        throw GaiaRunException('Codex refused the thread: $error');
      }
      thread = _string(_map(started, 'thread', ''), 'id', '');
      await onNewThread?.call(thread);
    } else {
      thread = threadId;
      if (!_loaded.contains(thread)) {
        try {
          await _request('thread/resume', {
            'threadId': thread,
            'model': model,
            'approvalPolicy': 'on-request',
          });
        } on _RpcError catch (error) {
          return GaiaTurnResult(
            sessionId: thread,
            // Only a missing thread: another failure keeps the chat on it.
            // The contract check fails if Codex rewords this.
            sessionFound: !error.message.contains('no rollout found'),
            isError: true,
            text: error.message,
          );
        }
      }
    }
    _loaded.add(thread);
    final turn = _turns[thread] = _Turn(tools, onEvent);
    // It can fail before it's returned: stopped, or the process gone.
    turn.done.future.ignore();
    onThread?.call(thread);
    try {
      final started = await _request('turn/start', {
        'threadId': thread,
        'model': model,
        'input': input,
      });
      turn.turnId ??= _string(_map(started, 'turn', ''), 'id', '');
    } on _RpcError catch (error) {
      if (_turns[thread] == turn) _turns.remove(thread);
      throw GaiaRunException('Codex refused the turn: $error');
    }
    // Stopped while it was starting.
    if (_turns[thread] != turn) _interrupt(thread, turn);
    return turn.done.future;
  }

  /// Interrupts [threadId]'s turn, which fails at once.
  void stop(String threadId) {
    final turn = _turns.remove(threadId);
    if (turn == null) return;
    _interrupt(threadId, turn);
    turn.done.completeError(GaiaRunException('Stopped'));
  }

  void _interrupt(String threadId, _Turn turn) {
    if (turn.turnId case final turnId?) {
      unawaited(
        _request('turn/interrupt', {
          'threadId': threadId,
          'turnId': turnId,
        }).then((_) {}, onError: (_) {}),
      );
    }
  }

  /// The process died or can't be read: every turn and request fails.
  void failAll(String reason) {
    final turns = [..._turns.values];
    final pending = [..._pending.values];
    _turns.clear();
    _pending.clear();
    for (final turn in turns) {
      turn.done.completeError(GaiaRunException(reason));
    }
    for (final request in pending) {
      request.completeError(GaiaRunException(reason));
    }
  }

  /// Throws a [CodexParseException] on a line it can't read.
  void onLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw CodexParseException('not JSON', line);
    }
    if (decoded is! Map<String, Object?>) {
      throw CodexParseException('not an object', line);
    }
    final id = decoded['id'];
    final method = decoded['method'];
    if (method is String && id != null) {
      unawaited(_answer(id, method, _map(decoded, 'params', line), line));
    } else if (id is int) {
      final request = _pending.remove(id);
      if (request == null) return;
      if (decoded['error'] case final Map<String, Object?> error) {
        request.completeError(_RpcError('${error['message']}'));
      } else {
        request.complete(_map(decoded, 'result', line));
      }
    } else if (method is String) {
      _notification(method, _map(decoded, 'params', line), line);
    }
  }

  void _notification(String method, Map<String, Object?> params, String line) {
    if (!const {
      'item/started',
      'item/completed',
      'item/agentMessage/delta',
      'thread/tokenUsage/updated',
      'error',
      'turn/started',
      'turn/completed',
    }.contains(method)) {
      return;
    }
    final threadId = _string(params, 'threadId', line);
    final turn = _turns[threadId];
    switch (method) {
      case 'item/started':
        final item = _map(params, 'item', line);
        switch (_string(item, 'type', line)) {
          case 'agentMessage':
            turn?.held = '';
            turn?.onEvent(const GaiaTextStart());
          case 'fileChange':
            _changes[_string(item, 'id', line)] = _field<List<Object?>>(
              item,
              'changes',
              line,
            );
        }
      case 'item/agentMessage/delta':
        if (turn == null) return;
        final text = turn.held + _string(params, 'delta', line);
        final kept = text.trimRight();
        turn.held = text.substring(kept.length);
        if (kept.isNotEmpty) turn.onEvent(GaiaTextDelta(kept));
      case 'item/completed':
        final item = _map(params, 'item', line);
        final type = _string(item, 'type', line);
        _changes.remove(item['id']);
        if (turn == null) return;
        if (type == 'agentMessage') {
          turn.lastText = _string(item, 'text', line).trimRight();
        } else if (!_notTools.contains(type)) {
          turn.onEvent(
            GaiaToolUse(
              type == 'dynamicToolCall'
                  ? _string(item, 'tool', line)
                  : _toolNames[type] ?? type,
            ),
          );
        }
      case 'thread/tokenUsage/updated':
        final last = _map(_map(params, 'tokenUsage', line), 'last', line);
        turn?.contextTokens = _field<int>(last, 'totalTokens', line);
      case 'error':
        if (params['willRetry'] == true || turn == null) return;
        turn.error = codexErrorText(
          _string(_map(params, 'error', line), 'message', line),
        );
      case 'turn/started':
        turn?.turnId ??= _string(_map(params, 'turn', line), 'id', line);
      case 'turn/completed':
        final ended = _map(params, 'turn', line);
        final status = _string(ended, 'status', line);
        if (turn == null) return;
        _turns.remove(threadId);
        switch (status) {
          case 'completed':
            turn.done.complete(
              GaiaTurnResult(
                sessionId: threadId,
                isError: false,
                text: turn.lastText,
                contextTokens: turn.contextTokens,
              ),
            );
          case 'interrupted':
            turn.done.completeError(
              GaiaRunException('Codex interrupted the turn'),
            );
          default:
            final error = ended['error'];
            turn.done.complete(
              GaiaTurnResult(
                sessionId: threadId,
                isError: true,
                text: error is Map<String, Object?>
                    ? codexErrorText(_string(error, 'message', line))
                    : turn.error ?? 'Codex failed the turn ($status)',
                contextTokens: turn.contextTokens,
              ),
            );
        }
    }
  }

  /// A request from the server, always answered: Codex waits on each.
  Future<void> _answer(
    Object id,
    String method,
    Map<String, Object?> params,
    String line,
  ) async {
    Map<String, Object?> result;
    try {
      final tools = _turns[_string(params, 'threadId', line)]?.tools;
      Future<bool> permit(String tool, Map<String, Object?> input) async {
        if (tools == null) return false;
        final decision = await tools.permit(
          tool: tool,
          input: input,
          description: params['reason'] as String? ?? '',
        );
        return decision.allow;
      }

      switch (method) {
        case 'item/tool/call':
          final answer = await gaiaMcpAnswer({
            'jsonrpc': '2.0',
            'id': 0,
            'method': 'tools/call',
            'params': {
              'name': _string(params, 'tool', line),
              'arguments': params['arguments'],
            },
          }, tools);
          final called = answer!['result']! as Map<String, Object?>;
          result = {
            'contentItems': [
              for (final content in called['content']! as List)
                {'type': 'inputText', 'text': (content as Map)['text']},
            ],
            'success': called['isError'] != true,
          };
        case 'item/commandExecution/requestApproval':
          final allow = await permit('Shell', {
            'command': params['command'] as String? ?? '',
            if (params['cwd'] case final String cwd) 'cwd': cwd,
          });
          result = {'decision': allow ? 'accept' : 'decline'};
        case 'item/fileChange/requestApproval':
          final changes = [
            for (final change
                in _changes[_string(params, 'itemId', line)] ?? const [])
              if (change is Map) change,
          ];
          final allow = await permit('Edit', {
            'path': changes.map((change) => change['path']).join('\n'),
            'diff': changes.map((change) => change['diff']).join('\n'),
          });
          result = {'decision': allow ? 'accept' : 'decline'};
        case 'item/permissions/requestApproval':
          final permissions = _map(params, 'permissions', line);
          final allow = await permit('Permissions', {
            ...permissions,
            if (params['cwd'] case final String cwd) 'cwd': cwd,
          });
          result = {
            'permissions': allow ? permissions : <String, Object?>{},
            'scope': 'turn',
          };
        default:
          return _send({
            'id': id,
            'error': {
              'code': -32601,
              'message': 'Gaia does not answer $method',
            },
          });
      }
    } catch (error) {
      debugPrint('[gaia] Codex request $method failed: $error');
      return _send({
        'id': id,
        'error': {'code': -32603, 'message': '$error'},
      });
    }
    _send({'id': id, 'result': result});
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = _nextId++;
    final request = _pending[id] = Completer<Map<String, Object?>>();
    _send({'id': id, 'method': method, 'params': params});
    return request.future;
  }

  void _send(Map<String, Object?> message) => _write(jsonEncode(message));

  static T _field<T>(Map<String, Object?> map, String key, String line) {
    final value = map[key];
    if (value is! T) throw CodexParseException('bad "$key"', line);
    return value;
  }

  static Map<String, Object?> _map(
    Map<String, Object?> map,
    String key,
    String line,
  ) => _field<Map<String, Object?>>(map, key, line);

  static String _string(Map<String, Object?> map, String key, String line) =>
      _field<String>(map, key, line);
}

const _idleTimeout = Duration(minutes: 10);

/// Runs chats on Codex's `app-server` (GAIA_HLD.md §5.1): one long-lived
/// process for every chat, each chat a thread on it and each message a
/// turn, the model chosen per turn. It's killed after 10 minutes with no
/// turn running; the next message resumes its thread on a new one.
///
/// Gaia's tools are client-hosted tools on each thread, answered by the
/// turn's [GaiaTurnTools], and so are the permission prompts Codex raises
/// under its `on-request` policy, as cards (§10.1). A thread keeps the tools
/// it started with, so one started with another set (an `exec` thread, or
/// one from before Gaia's tools changed) reports its session as not found,
/// and the chat is handed over to a new thread (§7.4).
///
/// It runs in Gaia's own Codex home, as [fallback] does: GAIA.md is its
/// AGENTS.md, and the login and Windows sandbox come from the user's. When
/// `app-server` can't start, every turn goes to [fallback], `codex exec`.
class CodexAppServerRunner implements GaiaAgentRunner {
  CodexAppServerRunner({
    required this.workingDirectory,
    required this.codexHome,
    required this.fallback,
    String? userCodexHome,
    this.onLine,
  }) : userCodexHome = userCodexHome ?? defaultUserCodexHome();

  final String workingDirectory;
  final String codexHome;
  final String userCodexHome;
  final CodexRunner fallback;

  /// Every line the server prints, before it's parsed.
  final void Function(String line)? onLine;

  _AppServerProcess? _process;
  Future<_AppServerProcess?>? _starting;
  var _unavailable = false;

  /// Each running chat's thread, once it has one.
  final _threads = <String, String>{};
  final _sending = <String>{};

  /// Chats stopped before their thread was known.
  final _stopped = <String>{};
  Timer? _idle;
  String? _instructions;

  /// GAIA.md changed mid-turn: the process goes once it's idle, so threads
  /// load the new AGENTS.md.
  var _restart = false;

  File get _threadTools => File(p.join(codexHome, 'gaia-threads.json'));
  Future<Map<String, Object?>>? _threadToolsRead;
  Future<void> _threadToolsWrite = Future.value();

  @override
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String prompt,
    List<GaiaImageInput> images = const [],
    Set<String> directories = const {},
    GaiaTurnTools? tools,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    Future<GaiaTurnResult> fallBack() => fallback.send(
      chatId: chatId,
      sessionId: sessionId,
      model: model,
      prompt: prompt,
      images: images,
      directories: directories,
      tools: tools,
      onEvent: onEvent,
    );
    if (_unavailable) return fallBack();
    final (:notReady, :sandbox) = await readyCodexHome(
      codexHome,
      userCodexHome,
    );
    if (notReady != null) return notReady;
    final threadTools = await (_threadToolsRead ??= _readThreadTools());
    if (sessionId != null && threadTools[sessionId] != kCodexToolsHash) {
      return GaiaTurnResult(
        sessionId: sessionId,
        sessionFound: false,
        isError: true,
        text: "This chat's Codex thread has another set of Gaia's tools.",
      );
    }
    final process = await (_starting ??= _start(sandbox));
    _starting = null;
    if (process == null) {
      _unavailable = true;
      return fallBack();
    }
    _idle?.cancel();
    _sending.add(chatId);
    try {
      return await process.client.send(
        threadId: sessionId,
        model: model,
        input: [
          {'type': 'text', 'text': codexPrompt(prompt, images)},
          for (final image in images)
            {'type': 'localImage', 'path': image.path},
        ],
        tools: tools,
        onEvent: onEvent,
        onThread: (threadId) {
          _threads[chatId] = threadId;
          if (_stopped.remove(chatId)) process.client.stop(threadId);
        },
        onNewThread: (threadId) {
          threadTools[threadId] = kCodexToolsHash;
          final json = jsonEncode(threadTools);
          // One write at a time: each holds every thread recorded so far.
          return _threadToolsWrite = _threadToolsWrite
              .catchError((_) {})
              .then((_) => _threadTools.writeAsString(json));
        },
      );
    } finally {
      _threads.remove(chatId);
      _sending.remove(chatId);
      _stopped.remove(chatId);
      // Not the client's turns: a send still starting its thread has none.
      if (_sending.isEmpty && _process == process) {
        _idle?.cancel();
        if (_restart) {
          _restart = false;
          unawaited(process.kill());
        } else {
          _idle = Timer(_idleTimeout, () => unawaited(process.kill()));
        }
      }
    }
  }

  Future<Map<String, Object?>> _readThreadTools() async {
    if (!await _threadTools.exists()) return {};
    try {
      return (jsonDecode(await _threadTools.readAsString()) as Map)
          .cast<String, Object?>();
    } on FormatException {
      return {};
    }
  }

  Future<_AppServerProcess?> _start(String? sandbox) async {
    final running = _process;
    if (running != null && !running.exited) return running;
    _AppServerProcess? process;
    try {
      process = await _AppServerProcess.start(
        workingDirectory: workingDirectory,
        codexHome: codexHome,
        sandbox: sandbox,
        onLine: onLine,
        onExit: (process) {
          if (_process == process) _process = null;
        },
      );
      await process.client.initialize().timeout(const Duration(seconds: 30));
      return _process = process;
    } catch (error) {
      debugPrint('[gaia] codex app-server unavailable, using exec: $error');
      await process?.kill();
      return null;
    }
  }

  @override
  bool isRunning(String chatId) =>
      _sending.contains(chatId) || fallback.isRunning(chatId);

  /// GAIA.md becomes the Codex home's AGENTS.md, which a thread reads when
  /// it's loaded: the process goes, now or once its turns end, and the
  /// next message resumes each thread under the new text.
  @override
  Future<void> setInstructions(String text) async {
    if (text == _instructions) return;
    _instructions = text;
    await fallback.setInstructions(text);
    final process = _process;
    if (process == null) return;
    if (_sending.isNotEmpty) {
      _restart = true;
    } else {
      _idle?.cancel();
      await process.kill();
    }
  }

  @override
  Future<void> stop(String chatId) async {
    if (_threads.remove(chatId) case final threadId?) {
      _process?.client.stop(threadId);
    } else if (_sending.contains(chatId)) {
      _stopped.add(chatId);
    }
    await fallback.stop(chatId);
  }

  @override
  Future<void> killAll() async {
    _idle?.cancel();
    _threads.clear();
    _stopped.clear();
    await Future.wait([?_process?.kill(), fallback.killAll()]);
  }
}

class _AppServerProcess {
  _AppServerProcess._(this.client);

  static Future<_AppServerProcess> start({
    required String workingDirectory,
    required String codexHome,
    required String? sandbox,
    required void Function(String line)? onLine,
    required void Function(_AppServerProcess process) onExit,
  }) async {
    late final CodexProcess codex;
    final server = _AppServerProcess._(
      CodexAppServerClient(
        (line) => codex.exited ? null : codex.stdin.writeln(line),
      ),
    );
    codex = server._codex = await CodexProcess.start(
      workingDirectory: workingDirectory,
      codexHome: codexHome,
      args: [
        'app-server',
        if (sandbox != null) ...['-c', 'windows.sandbox=$sandbox'],
      ],
      onRawLine: onLine,
      onLine: server.client.onLine,
      onFail: (reason) {
        if (codex.exited) onExit(server);
        server.client.failAll(reason);
      },
    );
    return server;
  }

  final CodexAppServerClient client;
  late final CodexProcess _codex;

  /// Also once it's being killed: no new turn should go to it.
  bool get exited => _codex.exited;

  /// Kills the whole tree: cmd, the server, and anything it started.
  Future<void> kill() => _codex.kill();
}

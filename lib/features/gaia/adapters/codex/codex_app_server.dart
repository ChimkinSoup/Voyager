// FRAGILE(cli): Codex's `codex app-server` JSON-RPC protocol, still marked
// experimental (observed on 0.166.0; `codex app-server generate-json-schema
// --experimental` prints it). Every shape read here has a recorded fixture
// under test/fixtures/gaia/codex_app_server/, which
// gaia_codex_app_server_test.dart replays. Re-record them, and move
// [kCodexTestedVersions], when a new CLI version is tested.
//
// What Gaia sends, one JSON object a line:
//   initialize {clientInfo, capabilities: {experimentalApi: true}}, then
//   the `initialized` notification; `experimentalApi` is what lets
//   thread/start take `dynamicTools`
//   thread/start {model, approvalPolicy: "on-request", dynamicTools,
//     developerInstructions?} -> {thread: {id}}; a thread keeps its tools
//     when it's resumed
//   thread/resume {threadId, model, approvalPolicy} -> an error when
//     there's no such thread ("no rollout found for thread id …"); a
//     thread keeps the developer instructions it started with, and ignores
//     new ones given on a resume (checked on 0.164.0)
//   turn/start {threadId, model, input: [text | localImage]} -> {turn: {id}}
//   turn/interrupt {threadId, turnId}
//   account/rateLimits/read {} (see usage/sources/codex_rate_limits.dart)
// What it reads:
//   item/started, item/completed {threadId, item: {id, type, …}}: types
//     agentMessage {text}, commandExecution, fileChange {changes: [{path,
//     diff}]}, dynamicToolCall {tool}, reasoning, userMessage and others
//   item/agentMessage/delta {threadId, delta}: the reply streams
//   thread/tokenUsage/updated {threadId, tokenUsage: {last: {totalTokens},
//     modelContextWindow?}}: the window not strict, since only a tooltip
//     shows it
//   error {threadId, error: {message}, willRetry}
//   turn/completed {threadId, turn: {status: completed | failed |
//     interrupted, error: {message}?}}
//   account/rateLimits/updated {rateLimits}: not strict, since only a usage
//     ring hangs on it, and the next read reports a changed shape
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
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/tools/gaia_tool_pipe.dart';
import 'package:voyager/features/gaia/usage/sources/codex_rate_limits.dart';

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
  int? contextWindow;
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

  /// Shell commands running, by thread: their item ids.
  final _commands = <String, Set<String>>{};

  bool get busy => _turns.isNotEmpty;

  /// Whether [threadId]'s turn has a shell command running. Codex's interrupt
  /// leaves it going (BUG-350), so a stop ends it.
  bool runningCommand(String threadId) =>
      _commands[threadId]?.isNotEmpty ?? false;

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
  /// error that keeps it. [instructions] are a new thread's developer
  /// instructions; a resumed thread keeps those it started with.
  Future<GaiaTurnResult> send({
    required String? threadId,
    required String model,
    required List<Map<String, Object?>> input,
    required GaiaTurnTools? tools,
    required void Function(GaiaAgentEvent event) onEvent,
    String instructions = '',
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
          if (instructions.isNotEmpty) 'developerInstructions': instructions,
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
    _commands.remove(threadId);
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
    if (method == 'account/rateLimits/updated') {
      // Other limit ids are a model's own, not the account's windows.
      if (params['rateLimits'] case {'limitId': 'codex'} && final limits) {
        if (codexUsage(limits, DateTime.now()) case final usage?) {
          for (final turn in _turns.values) {
            turn.onEvent(GaiaUsageUpdate(usage));
          }
        }
      }
      return;
    }
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
          case 'commandExecution':
            _commands
                .putIfAbsent(threadId, () => {})
                .add(_string(item, 'id', line));
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
        _commands[threadId]?.remove(item['id']);
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
        final usage = _map(params, 'tokenUsage', line);
        final last = _map(usage, 'last', line);
        turn?.contextTokens = _field<int>(last, 'totalTokens', line);
        // Only shown, so read leniently: a later update without it keeps
        // the one seen.
        if (turn != null) {
          turn.contextWindow =
              (usage['modelContextWindow'] as num?)?.toInt() ??
              turn.contextWindow;
        }
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
        _commands.remove(threadId);
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
                contextWindow: turn.contextWindow,
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
                contextWindow: turn.contextWindow,
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
                if ((content as Map)['type'] == 'image')
                  {
                    'type': 'inputImage',
                    'imageUrl':
                        'data:${content['mimeType']};base64,${content['data']}',
                  }
                else
                  {'type': 'inputText', 'text': content['text']},
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

  /// The account's usage windows (§6.2). Throws a [GaiaRunException] when
  /// the server refuses.
  Future<Map<String, Object?>> readRateLimits() async {
    try {
      return await _request('account/rateLimits/read', {});
    } on _RpcError catch (error) {
      throw GaiaRunException(error.message);
    }
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
/// AGENTS.md, and the login and Windows sandbox come from the user's. A
/// session's own instructions (§11) are the thread's developer
/// instructions. When `app-server` can't start, every turn goes to
/// [fallback], `codex exec`, without them.
class CodexAppServerRunner implements GaiaAgentRunner {
  CodexAppServerRunner({
    required this.workingDirectory,
    required this.codexHome,
    required this.fallback,
    String? userCodexHome,
    this.sandboxHome,
    this.onLine,
  }) : userCodexHome = userCodexHome ?? defaultUserCodexHome();

  final String workingDirectory;
  final String codexHome;
  final String userCodexHome;

  /// Whose config names the Windows sandbox; null for [userCodexHome].
  final String? sandboxHome;
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

  /// The server's processes as each running chat's turn began: any started
  /// since may be its commands.
  final _treeBefore = <String, Set<int>>{};
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
    String sessionInstructions = '',
    // Its home is the account: [CodexAccountRunners] picks the runner.
    GaiaAccount? account,
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
      sandboxHome: sandboxHome,
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
        instructions: sessionInstructions,
        onThread: (threadId) {
          // Once the thread is up, so what Codex starts with it, such as MCP
          // servers, is never taken for a command.
          _treeBefore[chatId] = _tree(process.pid, gaiaProcessParents());
          _threads[chatId] = threadId;
          if (_stopped.remove(chatId)) process.client.stop(threadId);
        },
        onNewThread: (threadId) => _recordThread(threadId, kCodexToolsHash),
      );
    } finally {
      _threads.remove(chatId);
      _sending.remove(chatId);
      _stopped.remove(chatId);
      _treeBefore.remove(chatId);
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

  /// `account/rateLimits/read`, on the process turns use so the home's login
  /// has one owner. One started just for this goes straight after, so idle
  /// polling leaves no server running. Throws a [GaiaRunException] when
  /// refused or when the server won't start.
  Future<Map<String, Object?>> readRateLimits() async {
    final running = _process;
    final wasRunning = running != null && !running.exited;
    // Reading needs no sandbox set up, unlike a turn.
    final (notReady: _, :sandbox) = await readyCodexHome(
      codexHome,
      userCodexHome,
      sandboxHome: sandboxHome,
    );
    final process = await (_starting ??= _start(sandbox));
    _starting = null;
    if (process == null) throw GaiaRunException('app-server unavailable');
    try {
      // Here, not just the caller's: a hung read must still reach the kill.
      return await process.client.readRateLimits().timeout(
        const Duration(seconds: 30),
      );
    } finally {
      if (!wasRunning && _sending.isEmpty && _process == process) {
        unawaited(process.kill());
      }
    }
  }

  Future<void> _recordThread(String threadId, Object? tools) async {
    final threadTools = await (_threadToolsRead ??= _readThreadTools());
    threadTools[threadId] = tools;
    final json = jsonEncode(threadTools);
    // One write at a time: each holds every thread recorded so far.
    return _threadToolsWrite = _threadToolsWrite
        .catchError((_) {})
        .then((_) => _threadTools.parent.create(recursive: true))
        .then((_) => _threadTools.writeAsString(json));
  }

  /// Takes in [source]'s thread: its rollout, at the same place under
  /// `sessions`, and the tools it was started with, or a resume here would
  /// hand it over to a new thread. A server already running here finds it
  /// (checked on 0.166.0). False when [source] doesn't have it.
  Future<bool> copyThreadFrom(
    CodexAppServerRunner source,
    String threadId,
  ) async {
    final sessions = Directory(p.join(source.codexHome, 'sessions'));
    if (!await sessions.exists()) return false;
    await for (final entry in sessions.list(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('-$threadId.jsonl')) continue;
      final copy = File(
        p.join(
          codexHome,
          'sessions',
          p.relative(entry.path, from: sessions.path),
        ),
      );
      await copy.parent.create(recursive: true);
      await entry.copy(copy.path);
      final tools = await (source._threadToolsRead ??= source
          ._readThreadTools());
      if (tools[threadId] case final hash?) {
        await _recordThread(threadId, hash);
      }
      return true;
    }
    return false;
  }

  Future<Map<String, Object?>> _readThreadTools() async {
    if (!await _threadTools.exists()) return {};
    try {
      final json = jsonDecode(await _threadTools.readAsString());
      return json is Map ? json.cast<String, Object?>() : {};
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

  /// Whether any turn is running, here or on [fallback].
  bool get busy => _sending.isNotEmpty || fallback.busy;

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
    var commands = const <int>[];
    if (_threads.remove(chatId) case final threadId?) {
      final process = _process;
      if (process != null && process.client.runningCommand(threadId)) {
        commands = _commandsOf(chatId, process);
      }
      process?.client.stop(threadId);
    } else if (_sending.contains(chatId)) {
      _stopped.add(chatId);
    }
    await Future.wait([
      for (final pid in commands)
        Process.run('taskkill', ['/t', '/f', '/pid', '$pid']).then((result) {
          if (result.exitCode != 0) {
            debugPrint(
              '[gaia] Codex command $pid not ended: '
              '${'${result.stderr}'.trim()}',
            );
          }
        }),
      fallback.stop(chatId),
    ]);
  }

  /// The processes [chatId]'s commands started, each the root of its own
  /// tree: under the server, started since its turn began. The server serves
  /// every chat on this account, so one that may be another chat's running
  /// command, started since that chat's turn began too, is left.
  List<int> _commandsOf(String chatId, _AppServerProcess process) {
    final before = _treeBefore[chatId];
    if (before == null) return const [];
    final others = [
      for (final MapEntry(key: other, value: tree) in _treeBefore.entries)
        if (other != chatId)
          if (_threads[other] case final thread?)
            if (process.client.runningCommand(thread)) tree,
    ];
    final parents = gaiaProcessParents();
    return [
      for (final pid in _tree(process.pid, parents))
        if (!before.contains(pid) &&
            before.contains(parents[pid]) &&
            others.every((tree) => tree.contains(pid)))
          pid,
    ];
  }

  /// [root] and every process under it.
  static Set<int> _tree(int root, Map<int, int> parents) {
    final children = <int, List<int>>{};
    for (final MapEntry(key: child, value: parent) in parents.entries) {
      children.putIfAbsent(parent, () => []).add(child);
    }
    final tree = {root};
    final queue = [root];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <int>[]) {
        if (tree.add(child)) queue.add(child);
      }
    }
    return tree;
  }

  @override
  Future<void> killAll() async {
    _idle?.cancel();
    _threads.clear();
    _stopped.clear();
    await Future.wait([?_process?.kill(), fallback.killAll()]);
  }
}

/// Codex on every account (§6.1): each its own [CodexAppServerRunner], so
/// its own Gaia-owned home under [homesRoot], `app-server` process and
/// `gaia-threads.json`. The login is copied from the account's folder; the
/// Windows sandbox is the machine's, from the user's own Codex config.
class CodexAccountRunners
    implements GaiaAgentRunner, GaiaSessionCopier, GaiaAccountKeeper {
  CodexAccountRunners({
    required this.workingDirectory,
    required this.homesRoot,
    this.toolPipe,
  });

  final String workingDirectory;
  final String homesRoot;
  final GaiaToolPipe? toolPipe;

  final _runners = <String, CodexAppServerRunner>{};
  String? _instructions;

  /// The accounts settings last named; null before they've said.
  Set<String>? _kept;

  @override
  Future<void> keepAccounts(Iterable<GaiaAccount> accounts) {
    _kept = {for (final account in accounts) account.id};
    return _prune();
  }

  /// Every home on disk, not just the runners here: an account may have gone
  /// while the companion wasn't running. Only the login goes: its threads
  /// stay. Called again as a run or read ends, which may have copied it back,
  /// and a file that won't delete waits for the next call.
  Future<void> _prune() async {
    final kept = _kept;
    final homes = Directory(homesRoot);
    if (kept == null || !await homes.exists()) return;
    try {
      await for (final home in homes.list()) {
        final id = p.basename(home.path);
        if (home is! Directory || kept.contains(id)) continue;
        final runner = _runners[id];
        if (runner != null && runner.busy) continue;
        _runners.remove(id);
        await runner?.killAll();
        final login = File(p.join(home.path, 'auth.json'));
        if (await login.exists()) await login.delete();
      }
    } on FileSystemException catch (error) {
      debugPrint('[gaia] removed Codex login not dropped yet: $error');
    }
  }

  Future<CodexAppServerRunner> _runner(GaiaAccount? account) async {
    final id = account?.id ?? kGaiaDefaultAccountId;
    final runner = _runners[id];
    if (runner != null) return runner;
    final login = account == null
        ? defaultUserCodexHome()
        : codexLoginHome(account);
    final home = p.join(homesRoot, id);
    final created = _runners[id] = CodexAppServerRunner(
      workingDirectory: workingDirectory,
      codexHome: home,
      userCodexHome: login,
      sandboxHome: defaultUserCodexHome(),
      fallback: CodexRunner(
        workingDirectory: workingDirectory,
        codexHome: home,
        userCodexHome: login,
        sandboxHome: defaultUserCodexHome(),
        toolPipe: toolPipe,
      ),
    );
    if (_instructions case final text?) await created.setInstructions(text);
    return created;
  }

  @override
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String prompt,
    List<GaiaImageInput> images = const [],
    Set<String> directories = const {},
    GaiaTurnTools? tools,
    String sessionInstructions = '',
    GaiaAccount? account,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    try {
      return await (await _runner(account)).send(
        chatId: chatId,
        sessionId: sessionId,
        model: model,
        prompt: prompt,
        images: images,
        directories: directories,
        tools: tools,
        sessionInstructions: sessionInstructions,
        onEvent: onEvent,
      );
    } finally {
      await _prune();
    }
  }

  /// [account]'s usage; see [CodexAppServerRunner.readRateLimits].
  Future<Map<String, Object?>> readRateLimits(GaiaAccount account) async {
    try {
      return await (await _runner(account)).readRateLimits();
    } finally {
      await _prune();
    }
  }

  @override
  Future<bool> copySession({
    required String sessionId,
    required GaiaAccount from,
    required GaiaAccount to,
  }) async =>
      (await _runner(to)).copyThreadFrom(await _runner(from), sessionId);

  @override
  bool isRunning(String chatId) =>
      _runners.values.any((runner) => runner.isRunning(chatId));

  /// A home made later gets it when it's first used.
  @override
  Future<void> setInstructions(String text) async {
    _instructions = text;
    await Future.wait([
      for (final runner in _runners.values) runner.setInstructions(text),
    ]);
  }

  @override
  Future<void> stop(String chatId) async {
    await Future.wait([
      for (final runner in _runners.values) runner.stop(chatId),
    ]);
  }

  @override
  Future<void> killAll() async {
    await Future.wait([for (final runner in _runners.values) runner.killAll()]);
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

  int get pid => _codex.pid;

  /// Also once it's being killed: no new turn should go to it.
  bool get exited => _codex.exited;

  /// Kills the whole tree: cmd, the server, and anything it started.
  Future<void> kill() => _codex.kill();
}

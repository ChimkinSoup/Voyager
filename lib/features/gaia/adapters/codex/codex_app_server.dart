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
//     when it's resumed. A tool-less one (GAIA_BTW_HLD.md §6) is
//     {model, approvalPolicy: "never", sandbox: "read-only",
//     environments: []}: with no environment it has no shell (checked on
//     0.166.0: asked to run a command, it says it can't). A tool-less fork
//     (§5.1) is thread/fork with that approvalPolicy and sandbox, then
//     turn/start with `environments: []`: no shell, and the source's
//     context kept (checked on 0.166.0). It keeps the source's dynamicTools,
//     which, with no turn tools, refuse every call
//   thread/resume {threadId, model, approvalPolicy} -> an error when
//     there's no such thread ("no rollout found for thread id …"), or a
//     forked one's `history_base` thread is missing ("invalid paginated
//     history lineage for <base>: missing source rollout"); a
//     thread keeps the developer instructions it started with, and ignores
//     new ones given on a resume (checked on 0.164.0)
//   turn/start {threadId, model, effort?, input: [text | localImage],
//     clientUserMessageId?} -> {turn: {id}}; the id is the Gaia message's,
//     kept with the turn's userMessage item as `clientId`. The effort holds
//     for the thread's later turns too, until one names another, so an
//     agent with none sends its model's default
//   model/list {includeHidden, cursor?} -> {data: [{id,
//     defaultReasoningEffort, supportedReasoningEfforts}], nextCursor}
//   thread/turns/list {threadId, cursor?} -> {data: [{id, items: [{type,
//     clientId?}]}], nextCursor}: works on a thread this process hasn't
//     loaded. Gaia finds a prompt's turn by its clientId, to fork there
//     (GAIA_REWIND_HLD.md §10.2)
//   thread/fork {threadId, lastTurnId, model, approvalPolicy, excludeTurns}
//     -> {thread: {id}}: a new thread with the turns up to lastTurnId, its
//     tools and instructions the source's. Checked on 0.166.0, from disk
//     with no resume first: it recalls a tool result from a kept turn, and
//     doesn't know a later one
//   turn/interrupt {threadId, turnId}
//   thread/revert {threadId, beforeTurnId}: the thread's saved history
//     without that turn and every later one, for a stopped turn taken back
//     (GAIA_HLD.md §9.6); its result isn't read, only whether it errs.
//     Checked on 0.166.0: the next turn, on the same server or one that
//     resumes the thread, doesn't see the reverted turn
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

/// What a tool [item] of [type] shows as: a client-hosted tool its own name.
String _toolName(String type, Map<String, Object?> item, String line) =>
    type == 'dynamicToolCall'
    ? CodexAppServerClient._string(item, 'tool', line)
    : _toolNames[type] ?? type;

/// What a tool [item] of [type] did: its command, query, paths or
/// arguments. Read leniently, since it's only shown.
String? _toolDetail(String type, Map<String, Object?> item) {
  String? lines(Object? list, String key) => list is List
      ? gaiaClipDetail(
          [
            for (final entry in list)
              if (entry is Map && entry[key] is String) entry[key] as String,
          ].join('\n'),
        )
      : null;
  return switch (type) {
    // The commands themselves, without the shell wrapping them.
    'commandExecution' =>
      lines(item['commandActions'], 'command') ??
          gaiaToolDetail(item, const ['command']),
    'webSearch' => gaiaToolDetail(item, const ['query']),
    'imageView' => gaiaToolDetail(item, const ['path']),
    'fileChange' => lines(item['changes'], 'path'),
    'mcpToolCall' => gaiaClipDetail(
      '${item['server']}/${item['tool']} ${jsonEncode(item['arguments'])}',
    ),
    'dynamicToolCall' => gaiaToolDetail(item['arguments']),
    _ => null,
  };
}

/// Codex's `/compact`: its app-server's own request, since as text the model
/// only claims to have compacted (GAIA_NATIVE_COMMANDS.md §6, checked on
/// 0.166.0).
const GaiaNativeCommand kCodexCompact = (
  name: 'compact',
  description: 'Free up context by summarizing the thread so far',
  argumentHint: '',
);

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

  /// Codex said the turn ended: for a stopped one, after [done] failed.
  final ended = Completer<void>();

  /// `turn/start` was refused: the thread never had its prompt.
  var refused = false;
  String? turnId;
  int? contextTokens;
  int? contextWindow;
  String? error;
  var lastText = '';

  /// A message's trailing whitespace, held back until more text follows: a
  /// block shouldn't end in a blank line.
  var held = '';

  /// The tool items shown as they started, by id: their detail and failure
  /// follow when they complete.
  final started = <String>{};
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

  /// The turn [stop] last ended on each thread, for [revert].
  final _stoppedTurns = <String, _Turn>{};

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
  /// a new thread, which [onNewThread] is told of: [fork]'s thread kept up
  /// to its turn, when given. [onThread] is told the turn's thread once
  /// [stop] can reach it. A resume that finds no thread, or a fork Codex
  /// refuses, ends with `sessionFound: false`; a resume that fails
  /// otherwise, with an error that keeps it. [instructions] are a new
  /// thread's developer instructions; a resumed or forked thread keeps those
  /// it started with. [clientId] names the prompt in the thread, for
  /// [turnOf]. [compact] compacts [threadId] instead of sending [input]: a
  /// turn of its own, with no reply (GAIA_NATIVE_COMMANDS.md §6).
  Future<GaiaTurnResult> send({
    required String? threadId,
    required String model,
    String? effort,
    required List<Map<String, Object?>> input,
    required GaiaTurnTools? tools,
    required void Function(GaiaAgentEvent event) onEvent,
    String instructions = '',
    String? clientId,
    GaiaForkCut? fork,
    void Function(String threadId)? onThread,
    Future<void> Function(String threadId)? onNewThread,
    bool compact = false,
    bool toolless = false,
  }) async {
    final String thread;
    if (threadId == null && fork != null) {
      final Map<String, Object?> forked;
      try {
        forked = await _request('thread/fork', {
          'threadId': fork.sessionId,
          'lastTurnId': fork.keepAt,
          'model': model,
          // A tool-less one's shell goes with its turn's environments.
          ...toolless
              ? {'approvalPolicy': 'never', 'sandbox': 'read-only'}
              : {'approvalPolicy': 'on-request'},
          'excludeTurns': true,
        });
      } on _RpcError catch (error) {
        return GaiaTurnResult(
          sessionId: fork.sessionId,
          sessionFound: false,
          isError: true,
          text: error.message,
        );
      }
      thread = _string(_map(forked, 'thread', ''), 'id', '');
      await onNewThread?.call(thread);
    } else if (threadId == null) {
      final Map<String, Object?> started;
      try {
        started = await _request(
          'thread/start',
          toolless
              ? {
                  'model': model,
                  'approvalPolicy': 'never',
                  'sandbox': 'read-only',
                  'environments': const <Object?>[],
                }
              : {
                  'model': model,
                  'approvalPolicy': 'on-request',
                  'dynamicTools': _dynamicTools,
                  if (instructions.isNotEmpty)
                    'developerInstructions': instructions,
                },
        );
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
            // Only a missing thread, or a fork missing the thread its history
            // starts in, which can never load: another failure keeps the
            // chat on it. The contract check fails if Codex rewords these.
            sessionFound:
                !error.message.contains('no rollout found') &&
                !error.message.contains('missing source rollout'),
            isError: true,
            text: error.message,
          );
        }
      }
    }
    _loaded.add(thread);
    // A stop's turn is only taken back straight after it.
    _stoppedTurns.remove(thread);
    final turn = _turns[thread] = _Turn(tools, onEvent);
    // It can fail before it's returned: stopped, or the process gone.
    turn.done.future.ignore();
    onThread?.call(thread);
    try {
      if (compact) {
        // Its turn's id comes with `turn/started` (checked on 0.166.0).
        await _request('thread/compact/start', {'threadId': thread});
      } else {
        final started = await _request('turn/start', {
          'threadId': thread,
          'model': model,
          'effort': ?effort,
          'input': input,
          'clientUserMessageId': ?clientId,
          // No shell, on a fork too, which keeps its source's.
          if (toolless) 'environments': const <Object?>[],
        });
        turn.turnId ??= _string(_map(started, 'turn', ''), 'id', '');
      }
    } on _RpcError catch (error) {
      if (_turns[thread] == turn) _turns.remove(thread);
      // No `turn/completed` will come for a stopped one to wait on.
      turn.refused = true;
      if (!turn.ended.isCompleted) turn.ended.complete();
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
    _stoppedTurns[threadId] = turn;
    _interrupt(threadId, turn);
    turn.done.completeError(GaiaRunException('Stopped'));
  }

  /// Takes [threadId]'s stopped turn out of its saved history, once Codex
  /// has ended it. Null once it's out, otherwise why not.
  Future<String?> revert(String threadId) async {
    final turn = _stoppedTurns[threadId];
    if (turn == null) return 'Codex was not running it.';
    // Still listed while it ends, for `turn/completed` to find.
    await turn.ended.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
    if (_stoppedTurns[threadId] == turn) _stoppedTurns.remove(threadId);
    if (turn.refused) return null;
    final turnId = turn.turnId;
    if (turnId == null) return 'Codex never said which turn it was.';
    try {
      await _request('thread/revert', {
        'threadId': threadId,
        'beforeTurnId': turnId,
      });
      return null;
    } on _RpcError catch (error) {
      return 'Codex refused to take it back: $error';
    } on GaiaRunException catch (error) {
      return 'Codex refused to take it back: $error';
    }
  }

  /// The id of [threadId]'s last turn whose prompt was sent as [clientId];
  /// null when it has none, as for a prompt sent before Gaia named them.
  /// Throws a [GaiaRunException] when Codex refuses.
  Future<String?> turnOf(String threadId, String clientId) async {
    String? cursor;
    do {
      final Map<String, Object?> page;
      try {
        page = await _request('thread/turns/list', {
          'threadId': threadId,
          // Newest first: the first match is the last turn.
          'sortDirection': 'desc',
          'cursor': ?cursor,
        });
      } on _RpcError catch (error) {
        throw GaiaRunException(error.message);
      }
      for (final turn in _field<List<Object?>>(page, 'data', '')) {
        if (turn is! Map<String, Object?>) {
          throw CodexParseException('bad turn', '$turn');
        }
        if (_field<List<Object?>>(turn, 'items', '').any(
          (item) =>
              item is Map &&
              item['type'] == 'userMessage' &&
              item['clientId'] == clientId,
        )) {
          return _string(turn, 'id', '');
        }
      }
      cursor = page['nextCursor'] as String?;
    } while (cursor != null);
    return null;
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
        // A tool shows as it starts, with what it was called with, so a
        // long command or one waiting on approval shows while it does.
        final type = _string(item, 'type', line);
        if (turn != null && !_notTools.contains(type)) {
          if (item['id'] case final String id) {
            turn.started.add(id);
            turn.onEvent(
              GaiaToolUse(
                _toolName(type, item, line),
                id: id,
                detail: _toolDetail(type, item),
              ),
            );
          }
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
          final detail = _toolDetail(type, item);
          final failure = codexToolFailure(item);
          if (item['id'] case final String id when turn.started.remove(id)) {
            // Shown as it started: what it ended up with.
            if (detail != null) turn.onEvent(GaiaToolDetails({id: detail}));
            if (failure != null) turn.onEvent(GaiaToolFailures({id: failure}));
          } else {
            turn.onEvent(
              GaiaToolUse(
                _toolName(type, item, line),
                detail: detail,
                failure: failure,
              ),
            );
          }
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
        if (turn == null) {
          if (_stoppedTurns[threadId]?.ended case final stopped?
              when !stopped.isCompleted) {
            stopped.complete();
          }
          return;
        }
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
          final answer = await gaiaMcpAnswer(
            {
              'jsonrpc': '2.0',
              'id': 0,
              'method': 'tools/call',
              'params': {
                'name': _string(params, 'tool', line),
                'arguments': params['arguments'],
              },
            },
            tools,
            callId: params['callId'] as String?,
          );
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

  /// [model]'s default thinking level, from `model/list`; null for a model
  /// it doesn't list, or when it fails.
  Future<String?> defaultEffort(String model) async =>
      (await (_defaultEfforts ??= _readDefaultEfforts()))[model];

  Future<Map<String, String>>? _defaultEfforts;

  Future<Map<String, String>> _readDefaultEfforts() async {
    final efforts = <String, String>{};
    String? cursor;
    try {
      do {
        final page = await _request('model/list', {
          'includeHidden': true,
          'cursor': ?cursor,
        });
        for (final model in _field<List<Object?>>(page, 'data', '')) {
          if (model is! Map<String, Object?>) continue;
          efforts[_string(model, 'id', '')] = _string(
            model,
            'defaultReasoningEffort',
            '',
          );
        }
        cursor = page['nextCursor'] as String?;
      } while (cursor != null);
    } on _RpcError catch (error) {
      debugPrint('[gaia] Codex model/list failed: $error');
    }
    return efforts;
  }

  /// The skills Codex finds for [cwd], enabled ones only, with their files
  /// (GAIA_NATIVE_COMMANDS.md §6). Read leniently, since they're only
  /// offered. Throws a [GaiaRunException] when the server refuses.
  Future<List<({String name, String description, String path})>> listSkills(
    String cwd,
  ) async {
    final Map<String, Object?> listed;
    try {
      listed = await _request('skills/list', {
        'cwds': [cwd],
      });
    } on _RpcError catch (error) {
      throw GaiaRunException(error.message);
    }
    return [
      if (listed['data'] case final List entries)
        for (final entry in entries)
          if (entry case {'skills': final List skills})
            for (final skill in skills)
              if (skill case {
                'name': final String name,
                'path': final String path,
                'enabled': true,
              })
                (
                  name: name,
                  description:
                      skill['shortDescription'] as String? ??
                      skill['description'] as String? ??
                      '',
                  path: path,
                ),
    ];
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

  /// Chats whose turn is on its way here, not yet [_sending].
  final _opening = <String>{};

  /// Chats stopped while [_opening]: the turn fails before its prompt goes,
  /// so [takeBack] has nothing to take.
  final _stoppedOpening = <String>{};

  /// The thread each chat's last stop was on, for [takeBack].
  final _stoppedThreads = <String, String>{};

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
    String? effort,
    required String prompt,
    List<GaiaImageInput> images = const [],
    Set<String> directories = const {},
    GaiaTurnTools? tools,
    String sessionInstructions = '',
    // Its home is the account: [CodexAccountRunners] picks the runner.
    GaiaAccount? account,
    String? promptId,
    GaiaForkCut? fork,
    bool toolless = false,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    // Before anything's awaited: a stop from here on is caught.
    _opening.add(chatId);
    _stoppedOpening.remove(chatId);
    try {
      final result = await _send(
        chatId: chatId,
        sessionId: sessionId,
        model: model,
        effort: effort,
        prompt: prompt,
        images: images,
        directories: directories,
        tools: tools,
        sessionInstructions: sessionInstructions,
        promptId: promptId,
        fork: sessionId == null ? fork : null,
        toolless: toolless,
        onEvent: onEvent,
      );
      // Stopped while it opened, then ended there with nothing sent (a home
      // not set up, a thread with other tools): stopped, not that.
      if (_stoppedOpening.contains(chatId)) throw GaiaRunException('Stopped.');
      return result;
    } finally {
      _opening.remove(chatId);
    }
  }

  Future<GaiaTurnResult> _send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String? effort,
    required String prompt,
    required List<GaiaImageInput> images,
    required Set<String> directories,
    required GaiaTurnTools? tools,
    required String sessionInstructions,
    required String? promptId,
    required GaiaForkCut? fork,
    required bool toolless,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    // A command of Codex's own (GAIA_NATIVE_COMMANDS.md §6): `/compact` is a
    // request of its own, and a skill goes as a skill input with the text.
    final command = RegExp(
      r'^/([\w-]+)(?:\s|$)',
    ).firstMatch(prompt.trim())?.group(1);
    final compact = command == kCodexCompact.name;
    if (compact && prompt.trim() != '/${kCodexCompact.name}') {
      return GaiaTurnResult(
        sessionId: sessionId ?? '',
        isError: true,
        text: "Codex's /compact takes no instructions.",
      );
    }
    if (compact && sessionId == null) {
      return const GaiaTurnResult(
        sessionId: '',
        isError: true,
        text: 'There is nothing to compact yet: this chat has no Codex thread.',
      );
    }
    final skill = _skills?.where((skill) => skill.name == command).firstOrNull;

    Future<GaiaTurnResult> fallBack() async {
      // Stopped while this one opened: never handed on.
      _opening.remove(chatId);
      if (_stoppedOpening.contains(chatId)) {
        throw GaiaRunException('Stopped.');
      }
      if (compact) {
        return GaiaTurnResult(
          sessionId: sessionId!,
          isError: true,
          text: "Codex's app-server isn't available, and only it can compact.",
        );
      }
      // Nor run without its shell.
      if (toolless) {
        return const GaiaTurnResult(
          sessionId: '',
          isError: true,
          text: "Codex's app-server isn't available to answer without tools.",
        );
      }
      // `codex exec` can't fork: the chat is handed over instead.
      if (fork != null) {
        return GaiaTurnResult(
          sessionId: fork.sessionId,
          sessionFound: false,
          isError: true,
          text: "Codex's app-server isn't available to fork the thread.",
        );
      }
      return fallback.send(
        chatId: chatId,
        sessionId: sessionId,
        model: model,
        effort: effort,
        prompt: prompt,
        images: images,
        directories: directories,
        tools: tools,
        onEvent: onEvent,
      );
    }

    if (_unavailable) return fallBack();
    final (:notReady, :sandbox) = await readyCodexHome(
      codexHome,
      userCodexHome,
      sandboxHome: sandboxHome,
    );
    if (notReady != null) return notReady;
    final threadTools = await (_threadToolsRead ??= _readThreadTools());
    // A fork keeps its source's tools.
    if ((sessionId ?? fork?.sessionId) case final thread?
        when threadTools[thread] != kCodexToolsHash) {
      return GaiaTurnResult(
        sessionId: thread,
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
    // From here a stop finds it [_sending].
    _opening.remove(chatId);
    _sending.add(chatId);
    // A stop's turn is only taken back straight after it.
    _stoppedThreads.remove(chatId);
    try {
      if (_stoppedOpening.contains(chatId)) throw GaiaRunException('Stopped.');
      final result = await process.client.send(
        threadId: sessionId,
        model: model,
        // Named every turn: a thread keeps the last one it was given, which
        // may be another agent's.
        effort: effort ?? await process.client.defaultEffort(model),
        compact: compact,
        input: [
          // Its instructions go with the text, which keeps the `/name`
          // (GAIA_NATIVE_COMMANDS.md §6).
          if (skill != null)
            {'type': 'skill', 'name': skill.name, 'path': skill.path},
          {'type': 'text', 'text': codexPrompt(prompt, images)},
          for (final image in images)
            {'type': 'localImage', 'path': image.path},
        ],
        tools: tools,
        onEvent: onEvent,
        instructions: sessionInstructions,
        clientId: promptId,
        fork: fork,
        toolless: toolless,
        onThread: (threadId) {
          // Once the thread is up, so what Codex starts with it, such as MCP
          // servers, is never taken for a command.
          _treeBefore[chatId] = _tree(process.pid, gaiaProcessParents());
          _threads[chatId] = threadId;
          if (_stopped.remove(chatId)) {
            _stoppedThreads[chatId] = threadId;
            process.client.stop(threadId);
          }
        },
        // A tool-less thread isn't recorded with Gaia's tools: one resumed
        // as a chat's would be handed over instead.
        onNewThread: (threadId) async {
          if (!toolless) await _recordThread(threadId, kCodexToolsHash);
        },
      );
      // A compaction has no reply of its own to show.
      if (compact && !result.isError) {
        onEvent(const GaiaTextStart());
        onEvent(const GaiaTextDelta('Compacted.'));
      }
      return result;
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

  /// `account/rateLimits/read`. Throws a [GaiaRunException] when refused or
  /// when the server won't start.
  Future<Map<String, Object?>> readRateLimits() =>
      _request((client) => client.readRateLimits());

  /// The skills [nativeCommands] last read, for a turn to send one by.
  List<({String name, String description, String path})>? _skills;

  /// `/compact` and the home's enabled skills (GAIA_NATIVE_COMMANDS.md §6);
  /// empty when the server can't say.
  Future<List<GaiaNativeCommand>> nativeCommands() async {
    try {
      final skills = await _request(
        (client) => client.listSkills(workingDirectory),
      );
      _skills = skills;
      return [
        kCodexCompact,
        for (final skill in skills)
          if (skill.name != kCodexCompact.name)
            (
              name: skill.name,
              description: skill.description,
              // A skill takes the request after it, so picking one waits
              // for it rather than sending.
              argumentHint: '[request]',
            ),
      ];
    } on GaiaRunException catch (error) {
      debugPrint('[gaia] Codex skills not read: $error');
      return const [];
    } on TimeoutException {
      return const [];
    }
  }

  /// The turn of the prompt [after] in [threadId], which a fork keeps up to
  /// (GAIA_REWIND_HLD.md §10.2); null when there's none, or Codex can't say.
  Future<String?> forkCut(String threadId, String after) async {
    try {
      return await _request((client) => client.turnOf(threadId, after));
    } on GaiaRunException catch (error) {
      debugPrint('[gaia] Codex fork cut of $threadId not found: $error');
      return null;
    } on CodexParseException catch (error) {
      debugPrint('[gaia] Codex fork cut of $threadId not read: $error');
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// [use] on the process turns use, so the home's login has one owner. One
  /// started just for this goes straight after, so idle polling leaves no
  /// server running. Throws a [GaiaRunException] when the server won't
  /// start.
  Future<T> _request<T>(
    Future<T> Function(CodexAppServerClient client) use,
  ) async {
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
      return await use(process.client).timeout(const Duration(seconds: 30));
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
  /// (checked on 0.166.0). A forked thread's earlier turns are read from the
  /// thread it was forked from, its `history_base`, which comes too unless
  /// it's here already: a copy here may have later turns. False when
  /// [source] doesn't have it.
  Future<bool> copyThreadFrom(
    CodexAppServerRunner source,
    String threadId, {
    bool keepExisting = false,
  }) async {
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
      if (keepExisting && await copy.exists()) return true;
      await copy.parent.create(recursive: true);
      await entry.copy(copy.path);
      if (await _historyBase(copy) case final base?) {
        await copyThreadFrom(source, base, keepExisting: true);
      }
      final tools = await (source._threadToolsRead ??= source
          ._readThreadTools());
      if (tools[threadId] case final hash?) {
        await _recordThread(threadId, hash);
      }
      return true;
    }
    return false;
  }

  /// The thread [rollout]'s history starts in, from its first line's
  /// `session_meta`; null for a thread that wasn't forked. Read leniently:
  /// without it, a copied fork only loses its earlier turns.
  static Future<String?> _historyBase(File rollout) async {
    try {
      final first = await rollout
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      return switch (jsonDecode(first)) {
        {
          'type': 'session_meta',
          'payload': {'history_base': {'thread_id': final String base}},
        } =>
          base,
        _ => null,
      };
    } on FormatException {
      return null;
    } on StateError {
      // Empty.
      return null;
    }
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
      _stoppedThreads[chatId] = threadId;
      final process = _process;
      if (process != null && process.client.runningCommand(threadId)) {
        commands = _commandsOf(chatId, process);
      }
      process?.client.stop(threadId);
    } else if (_sending.contains(chatId)) {
      _stopped.add(chatId);
    } else if (_opening.contains(chatId)) {
      _stoppedOpening.add(chatId);
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

  /// Whether [chatId]'s last stop was on a thread here.
  bool stoppedHere(String chatId) =>
      _stoppedThreads.containsKey(chatId) ||
      _stoppedOpening.contains(chatId) ||
      fallback.stoppedHere(chatId);

  /// A stop's turn is only taken back straight after it: a send on another
  /// account's runner ends that here.
  @override
  void forgetStop(String chatId) {
    _stoppedThreads.remove(chatId);
    _stoppedOpening.remove(chatId);
    fallback.forgetStop(chatId);
  }

  /// `thread/revert` before the turn [stop] ended, on the server it ran on.
  /// A turn `codex exec` ran can't be taken back; one stopped before its
  /// prompt went has nothing to take.
  @override
  Future<String?> takeBack(String chatId) async {
    if (_stoppedOpening.remove(chatId)) return null;
    if (fallback.stoppedHere(chatId)) return fallback.takeBack(chatId);
    final threadId = _stoppedThreads.remove(chatId);
    if (threadId == null) return 'Codex was not running it.';
    final process = _process;
    if (process == null || process.exited) {
      return "Codex's app-server ended before it could take it back.";
    }
    return process.client.revert(threadId);
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
    implements
        GaiaAgentRunner,
        GaiaSessionCopier,
        GaiaSessionForker,
        GaiaAccountKeeper,
        GaiaNativeCommander {
  CodexAccountRunners({
    required this.workingDirectory,
    required this.homesRoot,
    this.toolPipe,
  });

  final String workingDirectory;
  final String homesRoot;
  final GaiaToolPipe? toolPipe;

  final _runners = <String, CodexAppServerRunner>{};

  /// Chats whose turn hasn't reached its account's runner yet.
  final _opening = <String>{};

  /// Chats stopped while [_opening]: the turn fails before its prompt goes.
  final _stoppedOpening = <String>{};
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
    // Before anything's awaited: a stop from here on is caught.
    _opening.add(chatId);
    _stoppedOpening.remove(chatId);
    for (final runner in _runners.values) {
      runner.forgetStop(chatId);
    }
    try {
      final runner = await _runner(account);
      _opening.remove(chatId);
      if (_stoppedOpening.contains(chatId)) throw GaiaRunException('Stopped.');
      return await runner.send(
        chatId: chatId,
        sessionId: sessionId,
        model: model,
        effort: effort,
        prompt: prompt,
        images: images,
        directories: directories,
        tools: tools,
        sessionInstructions: sessionInstructions,
        promptId: promptId,
        fork: fork,
        toolless: toolless,
        onEvent: onEvent,
      );
    } finally {
      _opening.remove(chatId);
      await _prune();
    }
  }

  @override
  Future<List<GaiaNativeCommand>> nativeCommands(GaiaAccount? account) async {
    try {
      return await (await _runner(account)).nativeCommands();
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

  /// The turn of [after], which a fork keeps up to: the thread's turns are
  /// whole, so [next], [awaiting] and [endAt] aren't needed. A later turn,
  /// or one a pending fork record cuts at, comes after [after]'s.
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
    try {
      return await (await _runner(account)).forkCut(sessionId, after);
    } finally {
      await _prune();
    }
  }

  /// One app-server serves every chat, so there's no process to let go, and
  /// a take-back's revert is made at once, so none is pending. A stop's turn
  /// is only taken back straight after it, and this one's was kept.
  @override
  Future<void> rewound(String chatId, String forkId) async {
    for (final runner in _runners.values) {
      runner.forgetStop(chatId);
    }
  }

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
    if (_opening.contains(chatId)) _stoppedOpening.add(chatId);
    await Future.wait([
      for (final runner in _runners.values) runner.stop(chatId),
    ]);
  }

  @override
  Future<String?> takeBack(String chatId) async {
    // Stopped before a runner had it: nothing went.
    if (_stoppedOpening.remove(chatId)) return null;
    for (final runner in _runners.values) {
      if (runner.stoppedHere(chatId)) return runner.takeBack(chatId);
    }
    return 'Codex was not running it.';
  }

  @override
  void forgetStop(String chatId) {
    _stoppedOpening.remove(chatId);
    for (final runner in _runners.values) {
      runner.forgetStop(chatId);
    }
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

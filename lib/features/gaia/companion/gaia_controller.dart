import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';

const _uuid = Uuid();

/// How often a streaming reply is written through to the main instance. The
/// companion's own view updates on every delta.
const _persistEvery = Duration(seconds: 1);

/// A finished run, as Gaia's own toast shows it.
typedef GaiaRunToast = ({
  String chatId,
  String title,
  String body,
  bool error,
  bool question,
});

/// The companion's state: chats read from and written to the main instance,
/// runs on the Claude Code CLI, the window mode, Abort, and the drain before
/// an update (GAIA_HLD.md §3, §14, §15.7).
class GaiaController extends ChangeNotifier {
  GaiaController({
    required this._pipe,
    required this._window,
    required this._runner,
    this._cliVersion = claudeCodeVersion,
    this._exit = exit,
    GaiaDebug? debug,
    GaiaSidebar? sidebar,
  }) : debug = debug ?? GaiaDebug(),
       sidebar = sidebar ?? GaiaSidebar();

  final GaiaPipe _pipe;
  final GaiaWindow _window;
  final ClaudeCodeRunner _runner;

  /// The debug menu's toggles; scripted replies play on [_scripted].
  final GaiaDebug debug;
  final _scripted = GaiaScriptedRunner();

  /// The Gaia window's sidebar: open or not, and its width.
  final GaiaSidebar sidebar;

  /// Runs that finished in another chat while Gaia was on screen, for its
  /// own toast.
  Stream<GaiaRunToast> get toasts => _toasts.stream;
  final _toasts = StreamController<GaiaRunToast>.broadcast();

  /// `claude --version`, and how the companion ends: parameters for tests.
  final Future<(int, int, int)?> Function() _cliVersion;
  final void Function(int code) _exit;

  var aborted = false;
  var chats = <GaiaChat>[];

  /// Voyager's accent, as ARGB: the theme follows it.
  final accent = ValueNotifier(0xFF7C9EFF);

  /// On screen and in front, from the window's focus and blur; the
  /// starfield drifts only then.
  final focused = ValueNotifier(false);

  /// The main instance's device, whose native sessions this companion runs.
  var _deviceId = '';

  /// Whether a run that finishes while Gaia is hidden raises a toast (§14).
  var _notifyOnDone = true;

  /// Null for a new chat not yet sent.
  String? currentChatId;
  final _messages = <String, List<GaiaMessage>>{};

  /// What the content is laid out for; [GaiaWindow.show] says when it
  /// changes.
  var layout = GaiaMode.small;

  /// `claude --version`, once read; null when not installed.
  (int, int, int)? cliVersion;
  var cliChecked = false;

  /// Runs still going while an update or quit waits on them (§3.2); null
  /// when nothing is draining.
  int? draining;

  /// The user chose to wait for [draining]'s runs rather than cancel them.
  var drainWaiting = false;

  /// The drain's Cancel stopped the runs: their replies are `interrupted`.
  var _drainCancelled = false;

  /// The mode to go back to when a floater opened over the Gaia window is
  /// dismissed (§3.3).
  GaiaMode? _returnTo;

  final _stopping = <String>{};
  final _running = <String>{};
  final _lastPersist = <String, DateTime>{};

  GaiaChat? get currentChat =>
      chats.where((chat) => chat.id == currentChatId).firstOrNull;

  List<GaiaMessage> get messages =>
      currentChatId == null ? const [] : _messages[currentChatId] ?? const [];

  bool isRunning(String chatId) => _running.contains(chatId);

  bool get currentRunning =>
      currentChatId != null && _running.contains(currentChatId);

  Future<void> start() async {
    await _window.init();
    _pipe
      ..onEvent = _onEvent
      ..onRequest = _onRequest
      ..onConnected = () {
        unawaited(_onConnected());
      }
      // The main instance is gone, let go of this companion, or never
      // answered: a companion never outlives it.
      ..onDisconnected = () {
        _scripted.killAll();
        unawaited(_runner.killAll().whenComplete(() => _exit(0)));
      };
    if (!await _pipe.connect()) return _exit(0);
    unawaited(_checkCli());
  }

  Future<void> _onConnected() async {
    final hello = (await _pipe.request('hello'))! as Map;
    aborted = hello['aborted'] == true;
    accent.value = hello['accent']! as int;
    _deviceId = hello['deviceId']! as String;
    await _applySettings((hello['settings']! as Map).cast<String, Object?>());
    await _refresh();
  }

  Future<void> _checkCli() async {
    cliVersion = await _cliVersion();
    cliChecked = true;
    notifyListeners();
  }

  Future<void> _applySettings(Map<String, Object?> settings) async {
    _notifyOnDone = settings['notifyOnDone'] != false;
    await _runner.setInstructions(settings['gaiaMd'] as String? ?? '');
  }

  void _onEvent(String event, Map<String, Object?> params) {
    switch (event) {
      case 'hotkey':
        unawaited(onHotkey(params['key']! as String));
      case 'openChat':
        unawaited(openChat(params['chatId']! as String));
      case 'accent':
        accent.value = params['argb']! as int;
      case 'settings':
        unawaited(_applySettings(params));
      case 'changed':
        unawaited(_refresh());
    }
  }

  Future<Object?> _onRequest(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'abort':
        await _abort();
        return null;
      case 'stop':
        await stop(params['chatId']! as String);
        return null;
      case 'drain':
        return _drain();
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  /// Chats and messages changed in the main instance: written here, synced
  /// from another device, or pinned, renamed or deleted on the Gaia page.
  /// A chat running here keeps the messages it is writing.
  Future<void> _refresh() async {
    final list = (await _pipe.request('chats'))! as List;
    chats = [
      for (final chat in list)
        GaiaChat.fromJson((chat as Map).cast<String, Object?>()),
    ];
    final current = currentChatId;
    if (current != null &&
        !_running.contains(current) &&
        !chats.any((chat) => chat.id == current)) {
      currentChatId = null;
    }
    _messages.removeWhere(
      (chatId, _) => !_running.contains(chatId) && chatId != currentChatId,
    );
    notifyListeners();
    final shown = currentChatId;
    if (shown != null && !_running.contains(shown)) await _load(shown);
  }

  /// The hotkey table in §15.1.
  Future<void> onHotkey(String key) async {
    final shown = _window.shown;
    switch (key) {
      case 'small':
        if (shown == GaiaMode.small) return dismiss();
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.small);
      case 'large':
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.large);
      case 'window':
        await openWindow();
    }
  }

  Future<void> openWindow() async {
    _returnTo = null;
    await _show(GaiaMode.window);
  }

  /// A notification clicked, or a chat picked on the Gaia page.
  Future<void> openChat(String chatId) async {
    await openWindow();
    await selectChat(chatId);
  }

  /// Escape or close: a floater opened over the Gaia window turns back into
  /// it; anything else hides. Runs carry on (§14).
  Future<void> dismiss() async {
    final back = _returnTo;
    _returnTo = null;
    if (back != null && _window.shown != back) return _show(back);
    _window.hide();
  }

  Future<void> _show(GaiaMode mode) => _window.show(mode, () {
    layout = mode;
    notifyListeners();
  });

  void newChat() {
    currentChatId = null;
    notifyListeners();
  }

  Future<void> selectChat(String chatId) async {
    currentChatId = chatId;
    notifyListeners();
    if (_messages.containsKey(chatId)) return;
    await _load(chatId);
  }

  Future<void> _load(String chatId) async {
    final list = (await _pipe.request('messages', {'chatId': chatId}))! as List;
    // A run that started meanwhile has the newer list.
    if (_running.contains(chatId)) return;
    _messages[chatId] = [
      for (final message in list)
        GaiaMessage.fromJson((message as Map).cast<String, Object?>()),
    ];
    notifyListeners();
  }

  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || aborted || draining != null) return;
    var chat = currentChat;
    if (chat != null && _running.contains(chat.id)) return;
    final now = utcNow();
    if (chat == null) {
      // No utility model yet: the title is the first line (§5.1).
      final firstLine = prompt.split('\n').first;
      chat = GaiaChat(
        id: _uuid.v4(),
        title: firstLine.length > 60
            ? '${firstLine.substring(0, 60)}…'
            : firstLine,
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now,
      );
      chats = [chat, ...chats];
      _messages[chat.id] = [];
      currentChatId = chat.id;
      try {
        await _pipe.request('putChat', {'chat': chat.toJson()});
      } on GaiaPipeException catch (error) {
        // The main instance is going away: no run whose chat can't be kept.
        debugPrint('[gaia] chat not saved, not sending: $error');
        chats = [
          for (final c in chats)
            if (c.id != chat.id) c,
        ];
        _messages.remove(chat.id);
        if (currentChatId == chat.id) currentChatId = null;
        notifyListeners();
        return;
      }
    }
    final chatId = chat.id;
    final script = debug.scriptFor(prompt);
    final list = _messages[chatId] ??= [];
    final seq = list.isEmpty ? 0 : list.last.seq + 1;
    final question = GaiaMessage(
      id: _uuid.v4(),
      chatId: chatId,
      seq: seq,
      role: GaiaMessageRole.user,
      parts: [GaiaTextPart(prompt)],
      status: GaiaMessageStatus.complete,
      createdAt: now,
      updatedAt: now,
    );
    var reply = GaiaMessage(
      id: _uuid.v4(),
      chatId: chatId,
      seq: seq + 1,
      role: GaiaMessageRole.assistant,
      parts: const [],
      status: GaiaMessageStatus.streaming,
      createdAt: now,
      updatedAt: now,
      model: script == null ? kGaiaClaudeModel : 'gaia-debug-script',
    );
    list.addAll([question, reply]);
    _running.add(chatId);
    _moveToTop(chatId, now);
    _reportRuns();
    notifyListeners();
    unawaited(_persist(question));
    unawaited(_persist(reply));

    final builder = ClaudeTurnBuilder();
    final sessionId = chat.sessionOn(_deviceId);
    void onEvent(ClaudeEvent event) {
      if (!builder.apply(event)) return;
      reply = _replace(reply, reply.copyWith(parts: builder.parts));
      final last = _lastPersist[reply.id];
      if (last == null || DateTime.now().difference(last) > _persistEvery) {
        unawaited(_persist(reply));
      }
    }

    try {
      final result = script == null
          ? await _runner.send(
              chatId: chatId,
              sessionId: sessionId,
              newSessionId: sessionId ?? _uuid.v4(),
              prompt: prompt,
              onEvent: onEvent,
            )
          : await _scripted.send(
              chatId: chatId,
              script: script,
              replyDelay: debug.replyDelay,
              streamSpeed: debug.streamSpeed,
              onEvent: onEvent,
            );
      // Here at once, so a next message straight away resumes it; the main
      // instance's copy follows. A scripted reply has no session to resume.
      if (script == null) {
        if (_chat(chatId) case final current?) {
          final updated = current.copyWith(
            agentSessions: {
              ...current.agentSessions,
              gaiaSessionKey(_deviceId): GaiaAgentSession(
                sessionId: result.sessionId,
                lastSeq: reply.seq,
              ),
            },
          );
          chats = [for (final c in chats) c.id == chatId ? updated : c];
        }
        unawaited(
          _pipe
              .request('setSession', {
                'chatId': chatId,
                'sessionId': result.sessionId,
                'lastSeq': reply.seq,
              })
              .catchError((Object error) {
                debugPrint('[gaia] session not saved: $error');
                return null;
              }),
        );
      }
      final parts = builder.finished;
      reply = _replace(
        reply,
        result.isError
            ? reply.copyWith(
                parts: parts,
                status: GaiaMessageStatus.error,
                error: result.text,
              )
            : reply.copyWith(
                parts: parts,
                status: GaiaMessageStatus.complete,
                needsInput: gaiaEndsWithQuestion(
                  parts.whereType<GaiaTextPart>().lastOrNull?.text ?? '',
                ),
              ),
      );
    } catch (error) {
      final stopped = _stopping.contains(chatId);
      reply = _replace(
        reply,
        reply.copyWith(
          parts: builder.finished,
          status: aborted
              ? GaiaMessageStatus.aborted
              : _drainCancelled
              ? GaiaMessageStatus.interrupted
              : stopped
              ? GaiaMessageStatus.cancelled
              : GaiaMessageStatus.error,
          error: aborted || _drainCancelled || stopped ? null : '$error',
        ),
      );
    } finally {
      _stopping.remove(chatId);
      _running.remove(chatId);
      _lastPersist.remove(reply.id);
      _reportRuns();
      notifyListeners();
    }
    await _persist(reply);
    _reportDone(chatId, reply);
    _settleDrain();
  }

  Future<void> stop(String chatId) async {
    if (!_running.contains(chatId)) return;
    _stopping.add(chatId);
    _scripted.stop(chatId);
    await _runner.stop(chatId);
  }

  /// Tells the main instance which chats are running, for the tray and the
  /// Gaia page (§14).
  void _reportRuns() => _pipe.notify('runs', {
    'runs': [
      for (final chatId in _running)
        {'chatId': chatId, 'title': _chat(chatId)?.title ?? ''},
    ],
  });

  /// A reply that finished while Gaia was hidden, or its window behind other
  /// apps, raises a Windows toast (§14), one that ends on a question saying
  /// so (§10.1). In front, Gaia's own toast says the same, unless the chat is
  /// the one in view; a floater, topmost and so still on screen while
  /// another app has focus, shows it for every chat.
  void _reportDone(String chatId, GaiaMessage reply) {
    if (!_notifyOnDone || draining != null) return;
    final front = _window.foreground;
    if (front && chatId == currentChatId) return;
    final floating =
        _window.shown == GaiaMode.small || _window.shown == GaiaMode.large;
    final String title;
    final String body;
    switch (reply.status) {
      case GaiaMessageStatus.complete:
        title = reply.needsInput ? 'Gaia has a question' : 'Gaia is done';
        final line = reply.text.trim().split('\n').first;
        body = line.length > 120 ? '${line.substring(0, 120)}…' : line;
      case GaiaMessageStatus.error:
        title = 'Gaia ran into an error';
        body = reply.error ?? '';
      default:
        return;
    }
    final chatTitle = _chat(chatId)?.title ?? '';
    final toast = (
      chatId: chatId,
      title: title,
      body: chatTitle.isEmpty ? body : '$chatTitle: $body',
      error: reply.status == GaiaMessageStatus.error,
      question: reply.needsInput,
    );
    if (front || floating) {
      _toasts.add(toast);
      return;
    }
    _pipe.notify('runDone', {
      'chatId': toast.chatId,
      'title': toast.title,
      'body': toast.body,
    });
  }

  /// The main instance is about to quit or update (§3.2). With runs going,
  /// the Gaia window asks whether to wait for them or cancel them; `drained`
  /// follows once none are left.
  Future<Object?> _drain() async {
    final running = _running.length;
    if (running == 0) return {'running': 0};
    draining = running;
    drainWaiting = false;
    unawaited(openWindow());
    notifyListeners();
    return {'running': running};
  }

  void waitForDrain() {
    drainWaiting = true;
    notifyListeners();
  }

  /// Stops every run; each reply is kept, marked `interrupted`.
  Future<void> cancelDrain() async {
    _drainCancelled = true;
    _scripted.killAll();
    await _runner.killAll();
  }

  void _settleDrain() {
    if (draining == null) return;
    draining = _running.length;
    if (_running.isEmpty) {
      draining = null;
      _pipe.notify('drained');
    }
    notifyListeners();
  }

  /// Every run is killed with its process tree, and each reply it was
  /// writing saved as aborted, before the main instance hears back (§15.7).
  Future<void> _abort() async {
    aborted = true;
    final saves = <Future<void>>[];
    for (final list in _messages.values) {
      for (final message in list) {
        if (message.status != GaiaMessageStatus.streaming) continue;
        saves.add(
          _persist(
            _replace(
              message,
              message.copyWith(status: GaiaMessageStatus.aborted),
            ),
          ),
        );
      }
    }
    notifyListeners();
    _scripted.killAll();
    await Future.wait([_runner.killAll(), ...saves]);
  }

  Future<void> rearm() async {
    await _pipe.request('rearm');
    aborted = false;
    notifyListeners();
  }

  GaiaChat? _chat(String id) => chats.where((c) => c.id == id).firstOrNull;

  void _moveToTop(String chatId, DateTime at) {
    final chat = _chat(chatId)!;
    chats = [
      chat.copyWith(lastMessageAt: at),
      for (final c in chats)
        if (c.id != chatId) c,
    ];
  }

  /// Swaps [updated] in for [old] in its chat's list, and redraws.
  GaiaMessage _replace(GaiaMessage old, GaiaMessage updated) {
    final list = _messages[old.chatId];
    final index = list?.indexWhere((m) => m.id == old.id) ?? -1;
    if (index >= 0) list![index] = updated;
    notifyListeners();
    return updated;
  }

  Future<void> _persist(GaiaMessage message) async {
    _lastPersist[message.id] = DateTime.now();
    try {
      await _pipe.request('putMessage', {'message': message.toJson()});
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] message not saved: $error');
    }
  }
}

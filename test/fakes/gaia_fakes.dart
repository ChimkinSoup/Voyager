import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_executor.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/utility/claude_utility_runner.dart';

/// An in-memory [GaiaPipe]. The main instance's end is [FakeGaiaPipe.main];
/// each [startCompanion] on it makes a companion's end and hands it to
/// [onLaunch], as the native pipe does with a new process. Requests, results
/// and events go through JSON both ways, as on the real pipe.
class FakeGaiaPipe extends GaiaPipe {
  FakeGaiaPipe.main() : _main = null;

  FakeGaiaPipe._companion(FakeGaiaPipe main) : _main = main;

  /// Null on the main instance's end.
  final FakeGaiaPipe? _main;

  /// The other end while connected.
  FakeGaiaPipe? _peer;

  final _pending = <Completer<Object?>>{};

  /// A hung process: requests to this end are never answered, and events to
  /// it never arrive.
  var frozen = false;

  @override
  bool get connected => _peer != null;

  // The main instance's end.

  /// Gets each launched companion's end and its PID.
  void Function(FakeGaiaPipe companion, int pid)? onLaunch;

  /// Makes [startCompanion] fail, as when the exe can't be started.
  var failLaunch = false;

  /// Every [startCompanion] call, failed ones too.
  var startAttempts = 0;

  /// Every PID [startCompanion] handed out, in order.
  final launches = <int>[];
  var _nextPid = 1000;

  @override
  Future<int> startCompanion() async {
    assert(_main == null, 'startCompanion is the main instance end');
    startAttempts++;
    if (failLaunch) return 0;
    final pid = _nextPid++;
    launches.add(pid);
    onLaunch?.call(FakeGaiaPipe._companion(this), pid);
    return pid;
  }

  // The companion's end.

  @override
  Future<bool> connect() async {
    final main = _main;
    assert(main != null, 'connect is the companion end');
    if (main == null || main._peer != null) return false;
    _peer = main;
    main._peer = this;
    scheduleMicrotask(() {
      main.onConnected?.call();
      onConnected?.call();
    });
    return true;
  }

  /// The pipe breaks: the companion exited or was killed. On the main
  /// instance's end before any companion connected, it's one that exited
  /// first, which the main instance also hears as a disconnect.
  void disconnect() {
    final peer = _peer;
    for (final end in [this, ?peer]) {
      end._peer = null;
      final pending = [...end._pending];
      end._pending.clear();
      for (final completer in pending) {
        completer.completeError(GaiaPipeException('disconnected'));
      }
    }
    onDisconnected?.call();
    peer?.onDisconnected?.call();
  }

  @override
  Future<void> close() async {
    if (connected || _main == null) disconnect();
  }

  @override
  Future<Object?> request(String method, [Map<String, Object?>? params]) {
    final peer = _peer;
    if (peer == null) return Future.error(GaiaPipeException('not connected'));
    final completer = Completer<Object?>();
    _pending.add(completer);
    final sent = _params(params);
    unawaited(() async {
      if (peer.frozen) return;
      try {
        final handler = peer.onRequest;
        if (handler == null) throw GaiaPipeException('no handler');
        final result = _wire(await handler(method, sent));
        if (_pending.remove(completer)) completer.complete(result);
      } catch (error) {
        if (_pending.remove(completer)) {
          completer.completeError(GaiaPipeException('$error'));
        }
      }
    }());
    return completer.future;
  }

  @override
  void notify(String event, [Map<String, Object?>? params]) {
    final peer = _peer;
    if (peer == null || peer.frozen) return;
    final sent = _params(params);
    scheduleMicrotask(() => peer.onEvent?.call(event, sent));
  }

  static Object? _wire(Object? value) => jsonDecode(jsonEncode(value));

  static Map<String, Object?> _params(Map<String, Object?>? params) =>
      (_wire(params ?? const {})! as Map).cast<String, Object?>();
}

/// A [GaiaWindow] that only records the mode it's showing.
class FakeGaiaWindow implements GaiaWindow {
  @override
  GaiaMode? shown;

  /// Shown, but with another app in front.
  var behind = false;

  /// The frame the last [show] was given.
  GaiaFrame? frame;

  @override
  bool get foreground => shown != null && !behind;

  @override
  Future<void> init() async {}

  @override
  Future<void> show(
    GaiaMode mode,
    void Function() layout, {
    GaiaFrame? frame,
    bool behind = false,
  }) async {
    away = !foreground;
    shown = mode;
    this.frame = frame;
    this.behind = behind;
    layout();
  }

  @override
  void hide({bool between = false}) {
    shown = null;
    if (!between) returnTo = 0;
  }

  /// What the debug menu last set.
  var capturable = false;

  @override
  var returnTo = 0;

  @override
  void setCapturable(bool capturable) => this.capturable = capturable;

  @override
  void blurred() {
    if (shown == null) return;
    returnTo = 0;
    away = true;
  }

  @override
  var away = false;
}

/// One [FakeClaudeRunner.send] call.
typedef FakeClaudeSend = ({
  String chatId,
  String? sessionId,
  String model,
  String prompt,
  List<GaiaImageInput> images,
  Set<String> directories,
  GaiaTurnTools? tools,
});

/// A [GaiaAgentRunner] that plays scripted turns instead of running a CLI.
/// Each [send] takes the next of [turns], recorded Claude Code events: they
/// arrive one by one, as lines would, and a turn with no [ClaudeResult]
/// hangs after its events until [stop] or [killAll], which fail it as a
/// killed process does, or [finish] ends it. [sent] keeps each turn's
/// tools, for a test to call as the agent would.
class FakeClaudeRunner implements GaiaAgentRunner {
  /// Every GAIA.md the companion set, in order.
  final instructions = <String>[];

  @override
  Future<void> setInstructions(String text) async => instructions.add(text);

  final turns = <List<ClaudeEvent>>[];
  final sent = <FakeClaudeSend>[];
  var killAllCount = 0;
  final stopped = <String>[];

  /// Sessions a resume doesn't find, as when they belong to another
  /// Claude config folder.
  final missingSessions = <String>{};

  final _active = <String, Completer<GaiaTurnResult>>{};

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
    sent.add((
      chatId: chatId,
      sessionId: sessionId,
      model: model,
      prompt: prompt,
      images: images,
      directories: directories,
      tools: tools,
    ));
    if (turns.isEmpty) throw StateError('no scripted turn for "$prompt"');
    final events = turns.removeAt(0);
    final turn = _active[chatId] = Completer<GaiaTurnResult>();
    for (final event in events) {
      await Future<void>.microtask(() {});
      if (turn.isCompleted) break;
      if (gaiaEventOf(event) case final event?) onEvent(event);
      if (event is ClaudeResult) {
        turn.complete(
          GaiaTurnResult(
            sessionId: event.sessionId,
            isError: event.isError,
            text: event.text,
            contextTokens: event.contextTokens,
            sessionFound: !missingSessions.contains(sessionId),
          ),
        );
      }
    }
    try {
      return await turn.future;
    } finally {
      if (_active[chatId] == turn) _active.remove(chatId);
    }
  }

  @override
  bool isRunning(String chatId) => _active.containsKey(chatId);

  @override
  Future<void> stop(String chatId) async {
    stopped.add(chatId);
    _fail(_active.remove(chatId));
  }

  @override
  Future<void> killAll() async {
    killAllCount++;
    final active = [..._active.values];
    _active.clear();
    active.forEach(_fail);
  }

  /// [chatId]'s CLI dies on its own, mid-turn.
  void crash(String chatId) => _fail(_active.remove(chatId));

  /// Ends [chatId]'s hanging turn as a [ClaudeResult] would.
  void finish(String chatId, {String sessionId = 'session-1', String text = ''}) {
    final turn = _active.remove(chatId);
    if (turn == null || turn.isCompleted) return;
    turn.complete(
      GaiaTurnResult(sessionId: sessionId, isError: false, text: text),
    );
  }

  static void _fail(Completer<GaiaTurnResult>? turn) {
    if (turn == null || turn.isCompleted) return;
    turn.completeError(GaiaRunException('Claude Code exited (code 1)'));
  }
}

/// A recorded fixture's events, split into turns at each [ClaudeResult].
List<List<ClaudeEvent>> claudeFixtureTurns(String fixture) {
  final turns = <List<ClaudeEvent>>[[]];
  for (final line in File(
    'test/fixtures/gaia/claude_code/$fixture',
  ).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final event = parseClaudeLine(line);
    turns.last.add(event);
    if (event is ClaudeResult) turns.add([]);
  }
  return turns..removeWhere((turn) => turn.isEmpty);
}

/// A utility model whose jobs [answer] answers from their instructions,
/// recording each.
class FakeUtilityRunner implements ClaudeUtilityRunner {
  FakeUtilityRunner(this.answer);

  final String Function(String job) answer;
  final jobs = <String>[];

  /// Each job's images, in order.
  final images = <List<GaiaImageInput>>[];
  var warmed = 0;
  var model = '';
  var configDir = '';

  @override
  String get workingDirectory => '';

  @override
  void configure({required String model, required String configDir}) {
    this.model = model;
    this.configDir = configDir;
  }

  @override
  Future<void> warm() async => warmed++;

  @override
  Future<String> generate(
    String job,
    String input, {
    List<GaiaImageInput> images = const [],
  }) async {
    jobs.add(job);
    this.images.add(images);
    return answer(job);
  }
}

/// The executor's writes straight to the repositories, as the app's would
/// be, minus the uploads and providers.
class DirectGaiaWrites implements GaiaVoyagerWrites {
  DirectGaiaWrites(this.todos, this.calendar, this.journal);

  final TodoRepository todos;
  final CalendarRepository calendar;
  final JournalRepository journal;

  @override
  Future<void> saveTasks(List<TodoTask> tasks) async {
    for (final task in tasks) {
      await todos.upsertTask(task);
    }
  }

  @override
  Future<void> deleteTask(TodoTask task) => todos.softDeleteTask(task.id);

  @override
  Future<void> saveEvent(CalendarEvent event) => calendar.upsertEvent(event);

  @override
  Future<void> deleteEvent(String id) => calendar.softDeleteEvent(id);

  @override
  Future<void> createEntry(JournalEntry entry) => journal.upsertEntry(entry);

  @override
  Future<void> editEntry(
    String id,
    JournalEntry Function(JournalEntry current) apply,
  ) async => journal.upsertEntry(apply((await journal.getEntry(id))!));

  @override
  Future<void> deleteEntry(String id) => journal.softDeleteEntry(id);
}

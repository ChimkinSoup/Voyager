import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_routines.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

/// One item turn the runner asks for: its item chat [chatId], the [prompt],
/// and the [gate] its tools go through. [resume] goes on in the item's own
/// chat instead (§9.3, §10.2); [prompt] starts afresh if that chat is gone.
typedef GaiaItemTurn = ({
  GaiaRoutine routine,
  GaiaRunItem item,
  String chatId,
  String prompt,
  GaiaRoutineGate gate,
  String? resume,
});

/// A routine's materials as an item's prompt takes them (§8.2): each file's
/// text by name, and each upload's absolute path by name.
typedef GaiaRoutineMaterials = ({
  Map<String, String> files,
  Map<String, String> uploads,
});

/// Drives one routine run at a time on this device (GAIA_ROUTINES_HLD.md
/// §8): Dart runs the loop, one fresh item chat per item, not the model.
class GaiaRoutineRunner extends ChangeNotifier {
  GaiaRoutineRunner({
    required this.save,
    required this.sendItem,
    required this.stopItem,
    required this.focused,
    required this.materials,
    required this.planUsage,
    required this.submitted,
    required this.idle,
    this.gap = const Duration(seconds: 2),
    this.tick = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Keeps the run as it is now.
  final Future<void> Function(GaiaRoutineRun run) save;

  /// Runs an item's turn to its end; its reply's status, null when none.
  final Future<GaiaMessageStatus?> Function(GaiaItemTurn turn) sendItem;

  /// Stops [chatId]'s turn, as Stop does.
  final Future<void> Function(String chatId, String why) stopItem;

  /// The address of the window the item chat's os_ tools work on, null off a
  /// browser page.
  final Future<String?> Function(String chatId) focused;
  final Future<GaiaRoutineMaterials> Function(GaiaRoutine routine) materials;

  /// The plan windows of the accounts [GaiaRoutine.tier] runs on, read fresh
  /// (§8.8.2).
  final Future<Map<String, List<GaiaPlanWindow>>> Function(GaiaRoutine routine)
  planUsage;

  /// The normalized URLs submitted in any run so far, this one's too: the
  /// gate's duplicate check (§7.3).
  final Set<String> Function() submitted;

  /// How long since the user's last input anywhere: an attended handoff
  /// left this long parks its item (§9.3).
  final Duration Function() idle;
  final DateTime Function() _clock;

  /// Between items, a gap to press Esc in (§8.1).
  final Duration gap;

  /// How often an item's minutes are checked (§8.5).
  final Duration tick;

  /// This device's run while it's running or paused, and its routine.
  GaiaRoutineRun? run;
  GaiaRoutine? routine;

  /// The item turn under way, and its chat.
  GaiaRoutineGate? gate;
  String? itemChat;

  /// An attended handoff the run waits on (§9.3): its item chat and why.
  ({String chatId, String reason})? handoff;
  Completer<String?>? _handoffAnswer;

  /// What the run waits on the user for, attended (§9.3): a handoff, or an
  /// item's `ask_user`; null when it isn't.
  String? get waitingOnYou => handoff?.reason ?? gate?.asking;

  /// Why the run pauses, or ends, once the current item does.
  String? _pauseAfter;
  String? _endAfter;
  bool _looping = false;

  /// Starts [newRun] of [of] and runs it in the background.
  Future<void> start(GaiaRoutine of, GaiaRoutineRun newRun) async {
    routine = of;
    await _put(newRun);
    unawaited(_loop());
  }

  /// Takes back [paused], this device's run a restart, a cap or the user
  /// paused (§8.7).
  void adopt(GaiaRoutine of, GaiaRoutineRun paused) {
    routine = of;
    run = paused;
    notifyListeners();
  }

  /// Runs on from where the paused run stopped, with a [tokenCap] for this
  /// run only when given (§8.8.1). In an attended handoff, the item goes on
  /// in its own chat with [notes] (§9.3).
  Future<void> resume({int? tokenCap, String? notes}) async {
    if (_handoffAnswer case final answer? when !answer.isCompleted) {
      answer.complete(notes ?? '');
      return;
    }
    final current = run;
    if (current == null || current.state != GaiaRunState.paused || _looping) {
      return;
    }
    await _put(
      current.copyWith(
        state: GaiaRunState.running,
        clearStopReason: true,
        tokenCap: tokenCap,
      ),
    );
    unawaited(_loop());
  }

  /// Stops the current item as the user did, and pauses the run (§8.7).
  Future<void> pause([String why = 'stopped by you']) async {
    if (run?.state != GaiaRunState.running) return;
    if (_handoffAnswer case final answer? when !answer.isCompleted) {
      _pauseAfter ??= why;
      answer.complete(null);
    } else if ((gate, itemChat) case (final gate?, final chatId?)) {
      _pauseAfter ??= why;
      gate.stopped ??= (status: GaiaRunItemStatus.needsYou, reason: why);
      await stopItem(chatId, why);
    } else if (_looping) {
      _pauseAfter ??= why;
    } else {
      await _pauseNow(why);
    }
  }

  /// Ends the run: the current item stops, and no more start (§8.7).
  Future<void> end([String why = 'ended by you']) async {
    if (run == null) return;
    var stopping = false;
    if (_handoffAnswer case final answer? when !answer.isCompleted) {
      _endAfter = why;
      answer.complete(null);
      stopping = true;
    } else if ((gate, itemChat) case (final gate?, final chatId?)) {
      // The loop ends the run once the item is written, its last too.
      _endAfter = why;
      gate.stopped ??= (status: GaiaRunItemStatus.needsYou, reason: why);
      await stopItem(chatId, why);
      stopping = true;
    } else if (_looping) {
      // Between items: the loop ends the run before it starts another.
      _endAfter = why;
      stopping = true;
    }
    // The loop writes the item, then sees the run paused.
    while (stopping && _looping) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _endNow(why);
  }

  Future<void> _endNow(String why) async {
    final current = run;
    if (current == null) return;
    await _put(
      current.copyWith(
        state: GaiaRunState.ended,
        endedAt: utcNow(),
        stopReason: why,
      ),
    );
    run = null;
    routine = null;
    notifyListeners();
  }

  /// Tokens a model call spent in [chatId]'s turn (§8.8.1): counted when
  /// it's the item's, and at the cap the item stops.
  void tokens(String? chatId, Map<String, GaiaTokenCount> byModel) {
    final current = run;
    if (current == null || chatId == null || chatId != itemChat) return;
    final spent = byModel.values.fold(
      const GaiaTokenCount(),
      (total, count) => total + count,
    );
    final usage = current.usage.copyWith(
      input: current.usage.input + spent.input,
      output: current.usage.output + spent.output,
      cacheRead: current.usage.cacheRead + spent.cacheRead,
      cacheWrite: current.usage.cacheWrite + spent.cacheWrite,
    );
    run = current.copyWith(usage: usage);
    if (usage.counted >= _cap) {
      _pauseAfter ??= 'token cap';
      gate?.park('token cap reached');
    }
    notifyListeners();
  }

  /// The item turn's context changed (§8.5).
  void context(String chatId, int tokens) {
    if (chatId == itemChat) gate?.context(tokens);
  }

  /// Plan usage was read again mid-item (§8.8.2): at the routine's line the
  /// item wraps up, and at [kGaiaPlanStop] it stops.
  Future<void> planChanged() async {
    final (routine, gate) = (this.routine, this.gate);
    if (routine == null || gate == null || gate.finished) return;
    final line = gaiaPlanLine(await planUsage(routine), routine.wrapAt);
    if (line == null) return;
    _pauseAfter ??= gaiaPlanReason(line.window);
    if (line.window.used >= kGaiaPlanStop) {
      gate.park('plan usage at ${_percent(line.window.used)}');
    } else {
      gate.wrapUp(_percent(line.window.used));
    }
  }

  int get _cap => run?.tokenCap ?? routine?.tokenCap ?? 0;

  Future<void> _loop() async {
    if (_looping) return;
    _looping = true;
    notifyListeners();
    try {
      while (true) {
        if (_endAfter case final why?) {
          _endAfter = null;
          _pauseAfter = null;
          return await _endNow(why);
        }
        final (current, routine) = (run, this.routine);
        if (current == null ||
            routine == null ||
            current.state != GaiaRunState.running) {
          return;
        }
        final index = current.items.indexWhere(
          (item) => item.status == GaiaRunItemStatus.waiting,
        );
        if (index < 0) {
          await _put(
            current.copyWith(
              state: GaiaRunState.done,
              endedAt: utcNow(),
              usage: current.usage.copyWith(
                planEnd: gaiaPlanShares(await planUsage(routine)),
              ),
            ),
          );
          run = null;
          this.routine = null;
          // With no item left to run, the run is done rather than paused.
          _pauseAfter = null;
          return;
        }
        if (_pauseAfter case final why?) return await _pauseNow(why);
        if (current.usage.counted >= _cap) return await _pauseNow('token cap');
        final line = gaiaPlanLine(await planUsage(routine), routine.wrapAt);
        if (line != null) return await _pauseNow(gaiaPlanReason(line.window));
        // Paused or ended during the read: the next pass sees it.
        if (_pauseAfter != null || _endAfter != null) continue;
        await _item(routine, index);
        if (_pauseAfter == null && _endAfter == null) {
          await Future<void>.delayed(gap);
        }
      }
    } finally {
      _looping = false;
      notifyListeners();
    }
  }

  /// Runs item [index] in its item chat, and records how it ended (§8.1):
  /// a fresh chat, or on a retry the one it ran in before, whose tab is
  /// still open (§10.2). Attended, a handoff waits for the user's Resume
  /// and goes on in the same chat (§9.3).
  Future<void> _item(GaiaRoutine routine, int index) async {
    final previous = run!.items[index];
    final retrying = previous.chatId != null && previous.attempts > 0;
    final chatId = retrying ? previous.chatId! : newId();
    await _setItem(
      index,
      previous.copyWith(
        status: GaiaRunItemStatus.running,
        chatId: chatId,
        attempts: previous.attempts + 1,
        clearReason: true,
      ),
    );
    final material = await materials(routine);
    // Paused or ended before the item's turn started: it waits again.
    if (_pauseAfter != null || _endAfter != null) {
      return _setItemOf(chatId, (_) => previous);
    }
    var resume = retrying ? gaiaRetryMessage(previous.notes) : null;
    var posting = previous.posting;
    while (true) {
      final gate = await _turn(routine, chatId, material, resume, posting);
      final ended = run!.items.firstWhere((item) => item.chatId == chatId);
      if (run!.mode != GaiaRunMode.attended ||
          ended.status != GaiaRunItemStatus.needsYou ||
          _pauseAfter != null ||
          _endAfter != null) {
        return;
      }
      final notes = await _handoff(chatId, ended.reason ?? '');
      if (notes == null) return;
      resume = gaiaResumeMessage(notes);
      posting = gate.posting;
      await _setItemOf(
        chatId,
        (item) => item.copyWith(
          status: GaiaRunItemStatus.running,
          clearReason: true,
          notes: notes.trim().isEmpty
              ? null
              : [
                  if (item.notes case final kept? when kept.isNotEmpty) kept,
                  notes.trim(),
                ].join('\n'),
        ),
      );
    }
  }

  /// One turn of [chatId]'s item, fresh or going on with [resume], and its
  /// end written to the item.
  Future<GaiaRoutineGate> _turn(
    GaiaRoutine routine,
    String chatId,
    GaiaRoutineMaterials material,
    String? resume,
    Map<String, Object?>? posting,
  ) async {
    final index = run!.items.indexWhere((item) => item.chatId == chatId);
    final item = run!.items[index];
    final gate = this.gate = GaiaRoutineGate(
      routine: routine,
      mode: run!.mode,
      itemUrl: item.url,
      uploadPaths: [...material.uploads.values],
      isDuplicate: (url) => submitted().contains(gaiaNormalizeUrl(url)),
      focused: () => focused(chatId),
      stopTurn: (why) => unawaited(stopItem(chatId, why)),
      posting: posting,
      idle: idle,
      clock: _clock,
    )..changed = notifyListeners;
    itemChat = chatId;
    notifyListeners();
    final clock = Timer.periodic(tick, (_) => gate.checkTime());
    GaiaMessageStatus? status;
    Object? failure;
    try {
      status = await sendItem((
        routine: routine,
        item: item,
        chatId: chatId,
        prompt: gaiaItemPrompt(
          routine: routine,
          item: item,
          index: index,
          count: run!.items.length,
          materials: material.files,
          uploads: material.uploads,
          mode: run!.mode,
        ),
        gate: gate,
        resume: resume,
      ));
    } catch (error) {
      failure = error;
    } finally {
      clock.cancel();
      this.gate = null;
      itemChat = null;
    }
    // Stopped with no word from the gate: the user's Esc or Stop (§8.7).
    if (status == GaiaMessageStatus.cancelled && !gate.finished) {
      gate.stopped = (
        status: GaiaRunItemStatus.needsYou,
        reason: 'stopped by you',
      );
      _pauseAfter ??= 'stopped by you';
    }
    // Abort or Revoke ends the run; Gaia closing pauses it (§8.7).
    if (status == GaiaMessageStatus.aborted) {
      gate.stopped ??= (
        status: GaiaRunItemStatus.needsYou,
        reason: 'Gaia was aborted',
      );
      _endAfter = 'Gaia was aborted';
    } else if (status == GaiaMessageStatus.interrupted) {
      gate.stopped ??= (
        status: GaiaRunItemStatus.needsYou,
        reason: 'Gaia was closing',
      );
      _pauseAfter ??= 'Gaia was closing';
    }
    final end =
        !gate.finished && (failure != null || status == GaiaMessageStatus.error)
        ? (
            status: GaiaRunItemStatus.failed,
            reason: '${failure ?? 'the turn failed'}',
          )
        : gate.result;
    await _setItemOf(
      chatId,
      (item) => item.copyWith(
        status: end.status,
        reason: end.reason,
        posting: gate.posting,
        outcome: gate.outcome,
      ),
    );
    return gate;
  }

  /// Waits on an attended handoff (§9.3): the notes Resume gives, or null
  /// when the item is parked instead, by Pause, End, or 10 minutes with no
  /// input from the user.
  Future<String?> _handoff(String chatId, String reason) async {
    final answer = _handoffAnswer = Completer<String?>();
    final since = _clock();
    handoff = (chatId: chatId, reason: reason);
    notifyListeners();
    final watch = Timer.periodic(tick, (_) {
      if (!answer.isCompleted &&
          _clock().difference(since) >= kGaiaHandoffIdle &&
          idle() >= kGaiaHandoffIdle) {
        answer.complete(null);
      }
    });
    try {
      return await answer.future;
    } finally {
      watch.cancel();
      handoff = null;
      _handoffAnswer = null;
      notifyListeners();
    }
  }

  /// Puts parked [item] of [of] back in the queue with [note] (§10.2): in
  /// the run under way here, after the items still waiting; a finished run
  /// opens again to run it, a short run of the items retried. Why it can't,
  /// when it can't.
  Future<String?> retry(
    GaiaRoutine of,
    GaiaRoutineRun inRun,
    GaiaRunItem item, {
    String? note,
  }) async {
    final current = run;
    final target = current?.id == inRun.id ? current! : inRun;
    final index = target.items.indexWhere(
      (kept) => kept.url == item.url && kept.chatId == item.chatId,
    );
    if (index < 0 || !gaiaItemParked(target.items[index])) return null;
    final queued = gaiaQueueRetry(target, index, note: note);
    if (identical(target, current)) {
      // A paused run runs it on Resume run.
      await _put(queued);
      return null;
    }
    if (current != null) {
      return 'Another run is running or paused on this device. Resume or end '
          'it first.';
    }
    if (target.state != GaiaRunState.done &&
        target.state != GaiaRunState.ended) {
      return null;
    }
    routine = of;
    await _put(
      queued.copyWith(
        state: GaiaRunState.running,
        clearStopReason: true,
        clearEndedAt: true,
      ),
    );
    unawaited(_loop());
    return null;
  }

  Future<void> _setItem(int index, GaiaRunItem item) {
    final current = run!;
    return _put(current.copyWith(items: [...current.items]..[index] = item));
  }

  /// [change]s the item that runs in [chatId], wherever a retry has moved it
  /// in the list since.
  Future<void> _setItemOf(
    String chatId,
    GaiaRunItem Function(GaiaRunItem item) change,
  ) {
    final index = run!.items.indexWhere((item) => item.chatId == chatId);
    return _setItem(index, change(run!.items[index]));
  }

  Future<void> _pauseNow(String why) async {
    _pauseAfter = null;
    final current = run;
    if (current == null) return;
    await _put(current.copyWith(state: GaiaRunState.paused, stopReason: why));
  }

  Future<void> _put(GaiaRoutineRun next) async {
    run = next;
    notifyListeners();
    await save(next);
  }

  static String _percent(double used) => '${(used * 100).round()}%';
}

/// Each account's window shares, by window name, as a run's usage keeps
/// them (§5.2).
Map<String, Map<String, double>> gaiaPlanShares(
  Map<String, List<GaiaPlanWindow>> usage,
) => {
  for (final MapEntry(key: account, value: windows) in usage.entries)
    account: {for (final window in windows) window.name: window.used},
};

/// Why a run paused at the plan line: "plan usage: 5-hour limit at 96%".
String gaiaPlanReason(GaiaPlanWindow window) =>
    'plan usage: ${window.name} limit at ${(window.used * 100).round()}%';

/// A run found at start-up still running on this device: Gaia restarted
/// under it (§8.7). It's paused, and its running item needs you.
GaiaRoutineRun gaiaRestartedRun(GaiaRoutineRun run) => run.copyWith(
  state: GaiaRunState.paused,
  stopReason: 'Gaia restarted',
  items: [
    for (final item in run.items)
      item.status == GaiaRunItemStatus.running
          ? item.copyWith(
              status: GaiaRunItemStatus.needsYou,
              reason: 'Gaia restarted',
            )
          : item,
  ],
);

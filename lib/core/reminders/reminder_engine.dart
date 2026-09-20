import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_labels.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/reminder_schedule.dart';

enum ReminderSnooze { tenMinutes, tomorrow }

/// One reminder source — a scheduled rule or a bell — as it stands right now.
class ReminderSourceView {
  const ReminderSourceView({
    required this.sourceKey,
    required this.sourceKind,
    required this.sourceId,
    required this.title,
    required this.evaluation,
    required this.targetsThisDevice,
    this.subtitle,
    this.rule,
    this.task,
    this.event,
  });

  final String sourceKey;
  final ReminderSourceKind sourceKind;
  final String sourceId;
  final String title;
  final String? subtitle;

  /// Null for a rule that is switched off.
  final ReminderEvaluation? evaluation;

  /// False for a rule aimed at other devices only: it shows in the Inbox but
  /// never alerts here.
  final bool targetsThisDevice;

  final ScheduledReminderRule? rule;
  final TodoTask? task;
  final CalendarEvent? event;

  bool get isDue => targetsThisDevice && evaluation?.phase == ReminderPhase.due;
}

/// Works out which reminders are due on this device and delivers them
/// (`SCHEDULED_REMINDERS_HLD.md` §5): the sticky stack reads [due], the OS
/// notifier is kept in step, and acknowledge / snooze are written here.
///
/// Nothing about "due" is stored. Each evaluation is recomputed from the rules,
/// the bells, their entities and the synced delivery states, so an
/// acknowledgement that arrives by sync clears the sticky on the next
/// evaluation without anything to reconcile.
class ReminderEngine extends ChangeNotifier {
  ReminderEngine({
    required ReminderRepository repository,
    required ReminderOsNotifier os,
    required this.deviceId,
    required this.onStatesWritten,
    required this.onRulesWritten,
    required this.onLogWritten,
    DateTime Function()? clock,
  }) : _repository = repository,
       _os = os,
       _clock = clock ?? DateTime.now;

  final ReminderRepository _repository;
  final ReminderOsNotifier _os;
  final DateTime Function() _clock;
  final String deviceId;

  /// Called after a write so the providers the Inbox reads re-query.
  final VoidCallback onStatesWritten;
  final VoidCallback onRulesWritten;
  final void Function(String sourceKey) onLogWritten;

  List<ScheduledReminderRule>? _rules;
  List<EntityReminder>? _bells;
  Map<String, ReminderDeliveryState>? _states;
  Map<String, TodoTask>? _tasks;
  Map<String, CalendarEvent>? _events;

  /// Set when this device's registration was removed in Settings.
  var _removed = false;

  Map<String, ReminderSourceView> _views = const {};
  List<ReminderSourceView> _due = const [];
  String _viewSignature = '';
  Timer? _timer;
  var _disposed = false;

  /// Sticky appearances already logged this session, `sourceKey|instanceTag`.
  final _shown = <String>{};

  /// Supersessions already logged this session, `sourceKey|occurrenceKey`.
  final _superseded = <String>{};

  /// The occurrence each currently-due source was due for at the last
  /// evaluation — how a newer one replacing it unacknowledged is noticed.
  final _dueOccurrence = <String, String>{};

  String _alertSignature = '';

  String? _focusedSourceKey;
  int _focusGeneration = 0;

  /// Due reminders on this device, oldest first.
  List<ReminderSourceView> get due => _due;

  ReminderSourceView? view(String sourceKey) => _views[sourceKey];

  /// The sticky an OS notification tap asked to bring forward, and a counter
  /// that moves on every request so the same one can be asked for twice.
  String? get focusedSourceKey => _focusedSourceKey;
  int get focusGeneration => _focusGeneration;

  void focus(String sourceKey) {
    _focusedSourceKey = sourceKey;
    _focusGeneration++;
    notifyListeners();
  }

  /// Feeds the engine. A null argument leaves that input as it was; nothing is
  /// evaluated until every input has arrived once, so a bell is never judged
  /// against a task list that has not loaded yet.
  void updateInputs({
    List<ScheduledReminderRule>? rules,
    List<EntityReminder>? bells,
    List<ReminderDeliveryState>? states,
    List<TodoTask>? tasks,
    List<CalendarEvent>? events,
    bool? removed,
  }) {
    if (rules != null) _rules = rules;
    if (bells != null) _bells = bells;
    if (states != null) _states = {for (final s in states) s.id: s};
    if (tasks != null) _tasks = {for (final t in tasks) t.id: t};
    if (events != null) _events = {for (final e in events) e.id: e};
    if (removed != null) _removed = removed;
    _evaluate();
  }

  /// [fromTimer] marks the once-a-minute wake, which notifies whether or not
  /// anything moved: the Inbox counts down between events ("Next in 11
  /// minutes"), and nothing in the signature below changes as it does.
  void _evaluate({bool fromTimer = false}) {
    if (_disposed) return;
    final rules = _rules;
    final bells = _bells;
    final states = _states;
    final tasks = _tasks;
    final events = _events;
    if (rules == null ||
        bells == null ||
        states == null ||
        tasks == null ||
        events == null) {
      return;
    }
    final now = _clock();
    final views = <String, ReminderSourceView>{};

    for (final rule in rules) {
      if (rule.deletedAt != null) continue;
      final key = reminderSourceKey(ReminderSourceKind.scheduledRule, rule.id);
      views[key] = ReminderSourceView(
        sourceKey: key,
        sourceKind: ReminderSourceKind.scheduledRule,
        sourceId: rule.id,
        title: rule.title,
        subtitle: rule.body,
        rule: rule,
        targetsThisDevice: !_removed && rule.targets(deviceId),
        evaluation: rule.enabled
            ? evaluateReminder(
                latest: latestRuleOccurrence(rule, now),
                nextNatural: nextRuleFire(rule, now),
                state: states[key],
                now: now,
              )
            : null,
      );
    }

    for (final bell in bells) {
      if (bell.deletedAt != null || !bell.enabled) continue;
      switch (bell.sourceKind) {
        case ReminderSourceKind.todo:
          final task = tasks[bell.entityId];
          if (task == null) continue;
          final base = todoReminderBase(task);
          views[bell.id] = ReminderSourceView(
            sourceKey: bell.id,
            sourceKind: ReminderSourceKind.todo,
            sourceId: task.id,
            title: task.title.isEmpty ? '(untitled task)' : task.title,
            subtitle: base == null
                ? null
                : 'Due ${reminderWhenLabel(base, now)}',
            task: task,
            targetsThisDevice: !_removed,
            evaluation: evaluateReminder(
              latest: latestTodoOccurrence(task, bell, now),
              nextNatural: nextTodoFire(task, bell, now),
              state: states[bell.id],
              now: now,
            ),
          );
        case ReminderSourceKind.calendarEvent:
          final event = events[bell.entityId];
          if (event == null) continue;
          final evaluation = evaluateReminder(
            latest: latestEventOccurrence(event, bell, now),
            nextNatural: nextEventFire(event, bell, now),
            state: states[bell.id],
            now: now,
          );
          final occurrence = evaluation.occurrence;
          views[bell.id] = ReminderSourceView(
            sourceKey: bell.id,
            sourceKind: ReminderSourceKind.calendarEvent,
            sourceId: event.id,
            title: event.title.isEmpty ? '(untitled event)' : event.title,
            subtitle: occurrence == null
                ? null
                : event.isFullDay
                ? 'All day'
                : 'Starts ${reminderWhenLabel(occurrence.fireAt.add(Duration(minutes: bell.offsetMinutes)), now)}',
            event: event,
            targetsThisDevice: !_removed,
            evaluation: evaluation,
          );
        case ReminderSourceKind.scheduledRule:
          continue;
      }
    }

    _views = views;
    final due = views.values.where((v) => v.isDue).toList()
      ..sort(
        (a, b) => a.evaluation!.dueSince!.compareTo(b.evaluation!.dueSince!),
      );
    _due = due;

    _deliver(due, now);
    _syncScheduledAlerts(views.values, now);
    _armTimer(views.values, now);

    final signature = [
      for (final v in views.values)
        '${v.sourceKey}|${v.title}|${v.subtitle}|${v.targetsThisDevice}|'
            '${v.evaluation?.phase}|${v.evaluation?.instanceTag}|'
            '${v.evaluation?.snoozeUntil}|${v.evaluation?.nextFireAt}|'
            '${v.rule?.enabled}',
    ].join('\n');
    if (fromTimer || signature != _viewSignature) {
      _viewSignature = signature;
      notifyListeners();
    }
  }

  /// Logs each new sticky appearance, notices supersessions, and raises the
  /// in-app OS alert where the platform delivers that way.
  void _deliver(List<ReminderSourceView> due, DateTime now) {
    final dueKeys = <String>{};
    for (final view in due) {
      final evaluation = view.evaluation!;
      final occurrenceKey = evaluation.occurrence!.key;
      dueKeys.add(view.sourceKey);
      final previous = _dueOccurrence[view.sourceKey];
      _dueOccurrence[view.sourceKey] = occurrenceKey;
      if (!_shown.add('${view.sourceKey}|${evaluation.instanceTag}')) continue;

      final replaced = evaluation.supersededSnooze
          ? 'replaced a snooze'
          : (previous != null && previous != occurrenceKey)
          ? 'replaced $previous'
          : null;
      if (replaced != null &&
          _superseded.add('${view.sourceKey}|$occurrenceKey')) {
        unawaited(
          _log(view, ReminderLogEvent.supersededByNatural, detail: replaced),
        );
      }
      unawaited(_log(view, ReminderLogEvent.stickyShown));
      if (_os.raisesDueAlertsInApp) unawaited(_raiseOsAlertOnce(view));
    }
    for (final key in _dueOccurrence.keys.toList()) {
      if (dueKeys.contains(key)) continue;
      _dueOccurrence.remove(key);
      // Acknowledged or snoozed — here or on another device.
      unawaited(_os.dismiss(key));
    }
  }

  /// One OS alert per appearance per device, across restarts: the history
  /// already says whether this device raised it.
  Future<void> _raiseOsAlertOnce(ReminderSourceView view) async {
    final tag = view.evaluation?.instanceTag;
    if (tag == null) return;
    try {
      final history = await _repository.listLogs(
        deliveryStateId: view.sourceKey,
      );
      final raised = history.any(
        (log) =>
            log.eventType == ReminderLogEvent.osFired &&
            log.deviceId == deviceId &&
            log.detail == tag,
      );
      if (raised || _disposed) return;
      final shown = await _os.showNow(
        PlannedReminderAlert(
          sourceKey: view.sourceKey,
          title: view.title,
          body: view.subtitle,
          fireAt: _clock(),
        ),
      );
      if (shown) await _log(view, ReminderLogEvent.osFired, detail: tag);
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'raising a reminder alert');
    }
  }

  /// Hands the OS every upcoming alert, where the platform schedules ahead.
  /// Only when the plan changed: rescheduling cancels and rebuilds every alarm.
  void _syncScheduledAlerts(Iterable<ReminderSourceView> views, DateTime now) {
    if (_os.raisesDueAlertsInApp) return;
    final alerts = [
      for (final view in views)
        if (view.targetsThisDevice &&
            view.evaluation?.nextFireAt != null &&
            view.evaluation!.nextFireAt!.isAfter(now))
          PlannedReminderAlert(
            sourceKey: view.sourceKey,
            title: view.title,
            body: view.subtitle,
            fireAt: view.evaluation!.nextFireAt!,
          ),
    ]..sort((a, b) => a.fireAt.compareTo(b.fireAt));
    // Well under Android's 500-alarm ceiling; the rest are scheduled as the
    // nearer ones fire and the app re-evaluates.
    final planned = alerts.take(50).toList();
    final signature = [
      for (final alert in planned)
        '${alert.sourceKey}@${alert.fireAt.toIso8601String()}|'
            '${alert.title}|${alert.body}',
    ].join('\n');
    if (signature == _alertSignature) return;
    _alertSignature = signature;
    unawaited(_os.schedule(planned));
  }

  /// Wakes for the next fire time, and at least once a minute so a changed
  /// clock or timezone is picked up without an event to prompt it.
  void _armTimer(Iterable<ReminderSourceView> views, DateTime now) {
    _timer?.cancel();
    var delay = const Duration(minutes: 1);
    for (final view in views) {
      final next = view.evaluation?.nextFireAt;
      if (next == null) continue;
      final until = next.difference(now);
      if (until < delay) delay = until;
    }
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    _timer = Timer(delay, () => _evaluate(fromTimer: true));
  }

  /// Re-evaluates now — for an app resume, where timers may have slept.
  void refresh() => _evaluate();

  Future<void> acknowledge(String sourceKey) =>
      _act(sourceKey, ReminderDeliveryStatus.acked);

  Future<void> snooze(String sourceKey, ReminderSnooze snooze) =>
      _act(sourceKey, ReminderDeliveryStatus.snoozed, snooze: snooze);

  Future<void> _act(
    String sourceKey,
    ReminderDeliveryStatus status, {
    ReminderSnooze? snooze,
  }) async {
    final view = _views[sourceKey];
    final occurrence = view?.evaluation?.occurrence;
    if (view == null || occurrence == null) return;
    final now = utcNow();
    final local = _clock();
    final snoozeUntil = switch (snooze) {
      null => null,
      ReminderSnooze.tenMinutes => snoozeTenMinutesTarget(local),
      ReminderSnooze.tomorrow => snoozeTomorrowTarget(local),
    };
    // Read back rather than taken from the cached map, which a pull may have
    // moved on since the last evaluation.
    final current = await _repository.getDeliveryState(sourceKey);
    final state = ReminderDeliveryState(
      id: sourceKey,
      sourceKind: view.sourceKind,
      sourceId: view.sourceId,
      occurrenceKey: occurrence.key,
      status: status,
      snoozeUntil: snoozeUntil?.toUtc(),
      ackedAt: status == ReminderDeliveryStatus.acked ? now : null,
      createdAt: current?.createdAt ?? now,
      updatedAt: now,
      version: (current?.version ?? -1) + 1,
    );
    await _repository.upsertDeliveryState(state);
    _states = {...?_states, sourceKey: state};

    await _log(
      view,
      switch (snooze) {
        null => ReminderLogEvent.acked,
        ReminderSnooze.tenMinutes => ReminderLogEvent.snoozed10m,
        ReminderSnooze.tomorrow => ReminderLogEvent.snoozedTomorrow,
      },
      detail: snoozeUntil == null
          ? null
          : 'until ${snoozeUntil.toIso8601String()}',
    );

    // A one-shot that has been acknowledged is finished (§4.4).
    final rule = view.rule;
    if (status == ReminderDeliveryStatus.acked &&
        rule != null &&
        rule.scheduleKind == ReminderScheduleKind.once &&
        rule.enabled) {
      final completed = rule.copyWith(
        enabled: false,
        updatedAt: now,
        version: rule.version + 1,
      );
      await _repository.upsertRule(completed);
      _rules = [
        for (final r in _rules ?? const <ScheduledReminderRule>[])
          r.id == rule.id ? completed : r,
      ];
      onRulesWritten();
    }
    onStatesWritten();
    _evaluate();
  }

  Future<void> _log(
    ReminderSourceView view,
    ReminderLogEvent event, {
    String? detail,
  }) async {
    final now = utcNow();
    try {
      await _repository.appendLog(
        ReminderDeliveryLog(
          id: newId(),
          createdAt: now,
          updatedAt: now,
          deliveryStateId: view.sourceKey,
          sourceKind: view.sourceKind,
          sourceId: view.sourceId,
          occurrenceKey: view.evaluation?.occurrence?.key ?? '',
          eventType: event,
          deviceId: deviceId,
          at: now,
          detail: detail,
        ),
      );
      if (!_disposed) onLogWritten(view.sourceKey);
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'writing reminder history');
    }
  }

  void _report(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'ReminderEngine',
        context: ErrorDescription('while $context'),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

final reminderOsNotifierProvider = Provider<ReminderOsNotifier>(
  (ref) => createReminderOsNotifier(),
);

/// The one [ReminderEngine], fed from the providers every write and pull
/// already invalidates.
///
/// Inert until the device id is known: an evaluation under the placeholder id
/// would log history, and raise alerts, as a device that does not exist.
final reminderEngineProvider = ChangeNotifierProvider<ReminderEngine>((ref) {
  final deviceId = ref.watch(deviceIdProvider);
  final engine = ReminderEngine(
    repository: ref.watch(reminderRepositoryProvider),
    os: ref.watch(reminderOsNotifierProvider),
    deviceId: deviceId,
    onStatesWritten: () => ref.invalidate(reminderDeliveryStatesProvider),
    onRulesWritten: () => ref.invalidate(scheduledReminderRulesProvider),
    onLogWritten: (key) => ref.invalidate(reminderLogsProvider(key)),
  );
  if (deviceId == kUnresolvedDeviceId) return engine;

  ref.listen(scheduledReminderRulesProvider, (_, next) {
    engine.updateInputs(rules: next.valueOrNull);
  }, fireImmediately: true);
  ref.listen(entityRemindersProvider, (_, next) {
    engine.updateInputs(bells: next.valueOrNull);
  }, fireImmediately: true);
  ref.listen(reminderDeliveryStatesProvider, (_, next) {
    engine.updateInputs(states: next.valueOrNull);
  }, fireImmediately: true);
  ref.listen(allTodoTasksProvider, (_, next) {
    engine.updateInputs(tasks: next.valueOrNull);
  }, fireImmediately: true);
  ref.listen(calendarEventsProvider(null), (_, next) {
    engine.updateInputs(events: next.valueOrNull);
  }, fireImmediately: true);
  ref.listen(thisDeviceRegistrationProvider, (_, next) {
    final registration = next.valueOrNull;
    engine.updateInputs(removed: registration?.deletedAt != null);
  }, fireImmediately: true);
  return engine;
});

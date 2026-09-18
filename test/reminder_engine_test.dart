import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/reminders/device_registration.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// `SCHEDULED_REMINDERS_HLD.md` §5 and §11: what the engine delivers, what it
/// writes, and how a synced acknowledgement from another device lands.

class _FakeOs implements ReminderOsNotifier {
  _FakeOs({this.raisesDueAlertsInApp = true});

  @override
  final bool raisesDueAlertsInApp;

  final shown = <String>[];
  final dismissed = <String>[];
  final schedules = <List<PlannedReminderAlert>>[];

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<void> schedule(List<PlannedReminderAlert> alerts) async =>
      schedules.add(alerts);

  @override
  Future<bool> showNow(PlannedReminderAlert alert) async {
    if (!raisesDueAlertsInApp) return false;
    shown.add(alert.sourceKey);
    return true;
  }

  @override
  Future<void> dismiss(String sourceKey) async => dismissed.add(sourceKey);

  @override
  Future<String?> launchSourceKey() async => null;

  @override
  Future<ReminderPermission> permission() async => ReminderPermission.granted;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> openSystemSettings() async {}
}

const _deviceId = 'desk';

/// Lets the engine's unawaited history writes and alerts finish.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ScheduledReminderRule _rule({
  String id = 'r1',
  ReminderScheduleKind kind = ReminderScheduleKind.daily,
  DateTime? onceDate,
  List<String> targets = const [],
}) {
  final stamp = DateTime.utc(2026, 9, 1);
  return ScheduledReminderRule(
    id: id,
    createdAt: stamp,
    updatedAt: stamp,
    title: 'Vitamins',
    scheduleKind: kind,
    localTimeMinutes: 13 * 60,
    onceLocalDate: onceDate,
    targetDeviceIds: targets,
    armedAt: stamp,
  );
}

void main() {
  late AppDatabase db;
  late DriftReminderRepository repository;
  late DateTime now;
  final engines = <ReminderEngine>[];

  ReminderEngine engineWith(_FakeOs os) {
    final engine = ReminderEngine(
      repository: repository,
      os: os,
      deviceId: _deviceId,
      onStatesWritten: () {},
      onRulesWritten: () {},
      onLogWritten: (_) {},
      clock: () => now,
    );
    engines.add(engine);
    return engine;
  }

  Future<void> feed(
    ReminderEngine engine, {
    bool removed = false,
    List<TodoTask> tasks = const [],
  }) async {
    engine.updateInputs(
      rules: await repository.listRules(),
      bells: await repository.listEntityReminders(),
      states: await repository.listDeliveryStates(),
      tasks: tasks,
      events: const [],
      removed: removed,
    );
    await _settle();
  }

  setUp(() {
    db = AppDatabase.inMemory();
    repository = DriftReminderRepository(db);
    now = DateTime(2026, 9, 14, 13, 5);
  });

  tearDown(() async {
    for (final engine in engines) {
      engine.dispose();
    }
    engines.clear();
    await db.close();
  });

  test(
    'a due rule is stickied and alerted once per device, across restarts',
    () async {
      await repository.upsertRule(_rule());
      final os = _FakeOs();
      final engine = engineWith(os);
      await feed(engine);

      expect(engine.due.map((v) => v.sourceKey), ['rule:r1']);
      expect(os.shown, ['rule:r1']);

      // A relaunch finds the alert in the history and does not raise it again.
      final relaunched = engineWith(os);
      await feed(relaunched);
      expect(relaunched.due, hasLength(1));
      expect(os.shown, ['rule:r1']);

      final history = await repository.listLogs(deliveryStateId: 'rule:r1');
      expect(
        history.map((l) => l.eventType),
        containsAll([ReminderLogEvent.stickyShown, ReminderLogEvent.osFired]),
      );
      expect(history.every((l) => l.deviceId == _deviceId), isTrue);
    },
  );

  test('acknowledging writes the state and clears the sticky', () async {
    await repository.upsertRule(_rule());
    final engine = engineWith(_FakeOs());
    await feed(engine);

    await engine.acknowledge('rule:r1');
    await _settle();

    expect(engine.due, isEmpty);
    final state = await repository.getDeliveryState('rule:r1');
    expect(state!.status, ReminderDeliveryStatus.acked);
    expect(state.occurrenceKey, '2026-09-14T13:00');
    expect(state.version, 0);
  });

  test(
    'an acknowledgement synced from another device clears it here',
    () async {
      await repository.upsertRule(_rule());
      final os = _FakeOs(raisesDueAlertsInApp: false);
      final engine = engineWith(os);
      await feed(engine);
      expect(engine.due, hasLength(1));

      await repository.upsertDeliveryState(
        ReminderDeliveryState(
          id: 'rule:r1',
          sourceKind: ReminderSourceKind.scheduledRule,
          sourceId: 'r1',
          occurrenceKey: '2026-09-14T13:00',
          status: ReminderDeliveryStatus.acked,
          createdAt: DateTime.utc(2026, 9, 14),
          updatedAt: DateTime.utc(2026, 9, 14),
        ),
        recordLocalActivity: false,
      );
      await feed(engine);

      expect(engine.due, isEmpty);
      expect(os.dismissed, ['rule:r1']);
    },
  );

  test('snooze tomorrow targets tomorrow at the time it was pressed', () async {
    await repository.upsertRule(_rule());
    now = DateTime(2026, 9, 14, 15, 0);
    final engine = engineWith(_FakeOs());
    await feed(engine);

    await engine.snooze('rule:r1', ReminderSnooze.tomorrow);
    await _settle();

    final state = await repository.getDeliveryState('rule:r1');
    expect(state!.status, ReminderDeliveryStatus.snoozed);
    expect(state.snoozeUntil!.toLocal(), DateTime(2026, 9, 15, 15, 0));
    expect(engine.due, isEmpty);
    expect(
      (await repository.listLogs(deliveryStateId: 'rule:r1')).first.eventType,
      ReminderLogEvent.snoozedTomorrow,
    );
  });

  test('the natural occurrence replacing a snooze is logged', () async {
    await repository.upsertRule(_rule());
    await repository.upsertDeliveryState(
      ReminderDeliveryState(
        id: 'rule:r1',
        sourceKind: ReminderSourceKind.scheduledRule,
        sourceId: 'r1',
        occurrenceKey: '2026-09-13T13:00',
        status: ReminderDeliveryStatus.snoozed,
        snoozeUntil: DateTime(2026, 9, 14, 15, 0).toUtc(),
        createdAt: DateTime.utc(2026, 9, 13),
        updatedAt: DateTime.utc(2026, 9, 13),
      ),
    );
    final engine = engineWith(_FakeOs());
    await feed(engine);

    expect(engine.due.single.evaluation!.occurrence!.key, '2026-09-14T13:00');
    final history = await repository.listLogs(deliveryStateId: 'rule:r1');
    expect(
      history.map((l) => l.eventType),
      contains(ReminderLogEvent.supersededByNatural),
    );
  });

  test('a rule aimed at another device never delivers here', () async {
    await repository.upsertRule(_rule(targets: const ['tablet']));
    final os = _FakeOs(raisesDueAlertsInApp: false);
    final engine = engineWith(os);
    await feed(engine);

    expect(engine.due, isEmpty);
    expect(engine.view('rule:r1')!.targetsThisDevice, isFalse);
    expect(os.schedules.every((plan) => plan.isEmpty), isTrue);
  });

  test('a device removed in Settings delivers nothing', () async {
    await repository.upsertRule(_rule());
    final engine = engineWith(_FakeOs());
    await feed(engine, removed: true);
    expect(engine.due, isEmpty);
  });

  test('acknowledging a one-shot completes the rule', () async {
    await repository.upsertRule(
      _rule(kind: ReminderScheduleKind.once, onceDate: DateTime(2026, 9, 14)),
    );
    final engine = engineWith(_FakeOs());
    await feed(engine);
    expect(engine.due, hasLength(1));

    await engine.acknowledge('rule:r1');

    final rule = await repository.getRule('r1');
    expect(rule!.enabled, isFalse);
    expect(rule.version, 1);
  });

  test(
    'scheduling platforms get the next alert, and only when it changes',
    () async {
      await repository.upsertRule(_rule());
      final os = _FakeOs(raisesDueAlertsInApp: false);
      final engine = engineWith(os);
      now = DateTime(2026, 9, 14, 9, 0);
      await repository.upsertDeliveryState(
        ReminderDeliveryState(
          id: 'rule:r1',
          sourceKind: ReminderSourceKind.scheduledRule,
          sourceId: 'r1',
          occurrenceKey: '2026-09-13T13:00',
          status: ReminderDeliveryStatus.acked,
          createdAt: DateTime.utc(2026, 9, 13),
          updatedAt: DateTime.utc(2026, 9, 13),
        ),
      );
      await feed(engine);
      await feed(engine);

      expect(os.shown, isEmpty);
      expect(os.schedules, hasLength(1));
      expect(os.schedules.single.single.fireAt, DateTime(2026, 9, 14, 13, 0));
    },
  );

  test('a todo bell fires offset before the due time', () async {
    final stamp = DateTime.utc(2026, 9, 1);
    await repository.upsertEntityReminder(
      EntityReminder(
        id: 'todo:t1',
        createdAt: stamp,
        updatedAt: stamp,
        sourceKind: ReminderSourceKind.todo,
        entityId: 't1',
        enabled: true,
        offsetMinutes: 60,
        armedAt: stamp,
      ),
    );
    final task = TodoTask(
      id: 't1',
      createdAt: stamp,
      updatedAt: stamp,
      listId: 'l',
      title: 'Call the bank',
      dueDate: DateTime(2026, 9, 14, 14, 0).toUtc(),
    );
    final engine = engineWith(_FakeOs());
    await feed(engine, tasks: [task]);

    expect(engine.due.single.sourceKey, 'todo:t1');
    expect(engine.due.single.title, 'Call the bank');
  });

  test('registering a device creates it once and keeps a removal', () async {
    final first = DateTime.utc(2026, 9, 14, 8);
    await registerThisDevice(repository, _deviceId, now: first);
    final device = await repository.getDevice(_deviceId);
    expect(device!.lastSeenAt, first);

    // Within the refresh window nothing is written.
    await registerThisDevice(
      repository,
      _deviceId,
      now: first.add(const Duration(minutes: 5)),
    );
    expect((await repository.getDevice(_deviceId))!.version, 0);

    await repository.upsertDevice(
      device.copyWith(deletedAt: first, updatedAt: first, version: 1),
    );
    await registerThisDevice(
      repository,
      _deviceId,
      now: first.add(const Duration(days: 1)),
    );
    expect((await repository.getDevice(_deviceId))!.deletedAt, isNotNull);
  });

  test('createOnly registers a missing device and never rewrites one', () async {
    final first = DateTime.utc(2026, 9, 14, 8);
    // A launch whose pull never runs still gets this device listed.
    await registerThisDevice(
      repository,
      _deviceId,
      now: first,
      createOnly: true,
    );
    expect((await repository.getDevice(_deviceId))!.lastSeenAt, first);

    // Refreshing last-seen is the pull's job, so an existing row is left
    // alone however stale it is — a rename pulled from another device would
    // otherwise be overwritten by this one's copy.
    await registerThisDevice(
      repository,
      _deviceId,
      now: first.add(const Duration(days: 3)),
      createOnly: true,
    );
    final device = (await repository.getDevice(_deviceId))!;
    expect(device.lastSeenAt, first);
    expect(device.version, 0);
  });

  test('history is trimmed to the newest lines, as tombstones', () async {
    final stamp = DateTime.utc(2026, 9, 1);
    for (var i = 0; i < 5; i++) {
      await repository.appendLog(
        ReminderDeliveryLog(
          id: 'log$i',
          createdAt: stamp,
          updatedAt: stamp,
          deliveryStateId: 'rule:r1',
          sourceKind: ReminderSourceKind.scheduledRule,
          sourceId: 'r1',
          occurrenceKey: '',
          eventType: ReminderLogEvent.stickyShown,
          deviceId: _deviceId,
          at: stamp.add(Duration(minutes: i)),
        ),
        keep: 3,
      );
    }
    final live = await repository.listLogs(deliveryStateId: 'rule:r1');
    expect(live.map((l) => l.id), ['log4', 'log3', 'log2']);
    final all = await repository.listLogs(
      deliveryStateId: 'rule:r1',
      includeDeleted: true,
    );
    expect(all, hasLength(5));
  });
}

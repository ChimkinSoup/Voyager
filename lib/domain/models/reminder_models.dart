import 'package:voyager/domain/models/soft_deletable.dart';

/// What an installation runs on. Wider than `VoyagerPlatform`, which only
/// tells apart the two platforms this app ships on: a registration synced from
/// some future build has to be representable here.
enum DevicePlatform { android, ios, windows, macos, linux, web }

/// One installation that is signed in to the account, so a reminder can be
/// aimed at some devices and not others (`SCHEDULED_REMINDERS_HLD.md` §4.1).
///
/// [id] is the installation's device id — the one `ensureDeviceId` persists —
/// so a registration and the sync layer's `clientId` name the same thing.
class DeviceRegistration extends SoftDeletable {
  const DeviceRegistration({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.displayName,
    required this.platform,
    required this.lastSeenAt,
  });

  final String displayName;
  final DevicePlatform platform;
  final DateTime lastSeenAt;

  DeviceRegistration copyWith({
    String? displayName,
    DateTime? lastSeenAt,
    DateTime? updatedAt,
    int? version,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return DeviceRegistration(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      displayName: displayName ?? this.displayName,
      platform: platform,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}

enum ReminderScheduleKind { daily, weekly, once }

/// A reminder the user wrote in the Inbox's Scheduled section (§4.2).
///
/// Every kind fires at [localTimeMinutes] on the device's own wall clock, so a
/// reminder set for 8:00 AM still fires at 8:00 AM after the device changes
/// timezone.
class ScheduledReminderRule extends SoftDeletable {
  const ScheduledReminderRule({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.title,
    this.body,
    this.enabled = true,
    required this.scheduleKind,
    required this.localTimeMinutes,
    this.weeklyWeekdays = const {},
    this.onceLocalDate,
    this.targetDeviceIds = const [],
    required this.armedAt,
  });

  final String title;
  final String? body;
  final bool enabled;
  final ReminderScheduleKind scheduleKind;

  /// Minutes from local midnight, 0–1439.
  final int localTimeMinutes;

  /// For [ReminderScheduleKind.weekly]: [DateTime.monday] … [DateTime.sunday].
  final Set<int> weeklyWeekdays;

  /// For [ReminderScheduleKind.once]: a date-only local date.
  final DateTime? onceLocalDate;

  /// Empty means every registered device, including ones registered later.
  final List<String> targetDeviceIds;

  /// The instant the current schedule took effect. Occurrences before it are
  /// never due: creating a 9:00 AM daily reminder at noon must not raise this
  /// morning's, and neither must moving an existing one to 9:00 AM.
  ///
  /// Not [updatedAt], which also moves on a rename — and renaming a reminder
  /// that is due must not quietly clear it.
  final DateTime armedAt;

  bool targets(String deviceId) =>
      targetDeviceIds.isEmpty || targetDeviceIds.contains(deviceId);

  ScheduledReminderRule copyWith({
    String? title,
    String? body,
    bool clearBody = false,
    bool? enabled,
    ReminderScheduleKind? scheduleKind,
    int? localTimeMinutes,
    Set<int>? weeklyWeekdays,
    DateTime? onceLocalDate,
    bool clearOnceLocalDate = false,
    List<String>? targetDeviceIds,
    DateTime? armedAt,
    DateTime? updatedAt,
    int? version,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return ScheduledReminderRule(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      title: title ?? this.title,
      body: clearBody ? null : (body ?? this.body),
      enabled: enabled ?? this.enabled,
      scheduleKind: scheduleKind ?? this.scheduleKind,
      localTimeMinutes: localTimeMinutes ?? this.localTimeMinutes,
      weeklyWeekdays: weeklyWeekdays ?? this.weeklyWeekdays,
      onceLocalDate: clearOnceLocalDate
          ? null
          : (onceLocalDate ?? this.onceLocalDate),
      targetDeviceIds: targetDeviceIds ?? this.targetDeviceIds,
      armedAt: armedAt ?? this.armedAt,
    );
  }
}

/// `yyyy-MM-dd` for [ScheduledReminderRule.onceLocalDate], which is stored as
/// text: as an instant, each device would read it back shifted by its own UTC
/// offset.
String reminderLocalDateToString(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime? parseReminderLocalDate(String? value) {
  if (value == null) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

/// [T.values] by name, or [fallback] for a value written by a newer build.
T reminderEnumByName<T extends Enum>(
  List<T> values,
  String? name,
  T fallback,
) => values.asNameMap()[name] ?? fallback;

enum ReminderSourceKind { scheduledRule, todo, calendarEvent }

/// The id every reminder source goes by in [ReminderDeliveryState] and
/// [EntityReminder]: `rule:{id}`, `todo:{id}` or `calendarEvent:{id}`.
String reminderSourceKey(ReminderSourceKind kind, String sourceId) =>
    switch (kind) {
      ReminderSourceKind.scheduledRule => 'rule:$sourceId',
      ReminderSourceKind.todo => 'todo:$sourceId',
      ReminderSourceKind.calendarEvent => 'calendarEvent:$sourceId',
    };

/// The bell on a todo or calendar event (§4.5).
///
/// Its own record rather than fields on the task or event: a todo task is a
/// CRDT-backed document, and toggling a bell should neither bump the task's
/// version against a notes edit on another device nor ride through that
/// merge. [id] is [reminderSourceKey] of the entity.
class EntityReminder extends SoftDeletable {
  const EntityReminder({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.sourceKind,
    required this.entityId,
    required this.enabled,
    required this.offsetMinutes,
    required this.armedAt,
  });

  /// [ReminderSourceKind.todo] or [ReminderSourceKind.calendarEvent].
  final ReminderSourceKind sourceKind;
  final String entityId;
  final bool enabled;

  /// How long before the entity's base time to fire. 0 is "at time".
  final int offsetMinutes;

  /// As [ScheduledReminderRule.armedAt]: set when the bell is turned on or its
  /// offset changes.
  final DateTime armedAt;

  EntityReminder copyWith({
    bool? enabled,
    int? offsetMinutes,
    DateTime? armedAt,
    DateTime? updatedAt,
    int? version,
  }) {
    return EntityReminder(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt,
      sourceKind: sourceKind,
      entityId: entityId,
      enabled: enabled ?? this.enabled,
      offsetMinutes: offsetMinutes ?? this.offsetMinutes,
      armedAt: armedAt ?? this.armedAt,
    );
  }
}

/// What the user last did about a reminder source (§4.3).
///
/// Only the user's own actions are stored and synced. Whether something is
/// pending or due is worked out on each device from the rule and this row, so
/// devices never race each other to write "due" — an offline device writing
/// that over an acknowledgement from another one would resurrect it.
enum ReminderDeliveryStatus { acked, snoozed }

class ReminderDeliveryState {
  const ReminderDeliveryState({
    required this.id,
    required this.sourceKind,
    required this.sourceId,
    required this.occurrenceKey,
    required this.status,
    this.snoozeUntil,
    this.ackedAt,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
  });

  /// [reminderSourceKey] of the source: one row per source, which is what
  /// keeps a rule down to one sticky however many days go unacknowledged.
  final String id;
  final ReminderSourceKind sourceKind;
  final String sourceId;

  /// The occurrence the action was taken on. A newer natural occurrence has a
  /// different key, and that mismatch is what lets it replace a snooze.
  final String occurrenceKey;
  final ReminderDeliveryStatus status;

  /// Set while [status] is [ReminderDeliveryStatus.snoozed].
  final DateTime? snoozeUntil;
  final DateTime? ackedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
}

enum ReminderLogEvent {
  osFired,
  stickyShown,
  acked,
  snoozed10m,
  snoozedTomorrow,
  supersededByNatural,
}

/// One line of a reminder's debug history (§4.6).
///
/// Soft-deletable only so that trimming a long history reaches the other
/// devices; nothing else deletes a log line.
class ReminderDeliveryLog extends SoftDeletable {
  const ReminderDeliveryLog({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.deliveryStateId,
    required this.sourceKind,
    required this.sourceId,
    required this.occurrenceKey,
    required this.eventType,
    required this.deviceId,
    required this.at,
    this.detail,
  });

  final String deliveryStateId;
  final ReminderSourceKind sourceKind;
  final String sourceId;
  final String occurrenceKey;
  final ReminderLogEvent eventType;
  final String deviceId;
  final DateTime at;
  final String? detail;
}

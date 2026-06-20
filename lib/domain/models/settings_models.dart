class AppSettings {
  const AppSettings({
    this.accentColor = 0xFF7C9EFF,
    this.weekStartsOnMonday = true,
    this.showQuotes = true,
    this.journalHotkey = 'Ctrl+Shift+J',
    this.todoHotkey = 'Ctrl+Shift+T',
    this.rankingColorStart = 0xFF4CAF50,
    this.rankingColorEnd = 0xFFF44336,
    this.timelineModeYearZero = true,
    this.birthYear,
    this.alertOnPeriodicPrompts = false,
    this.alertTimeHour = 9,
    this.hideCompletedTasks = false,
  });

  final int accentColor;
  final bool weekStartsOnMonday;
  final bool showQuotes;
  final String journalHotkey;
  final String todoHotkey;
  final int rankingColorStart;
  final int rankingColorEnd;
  final bool timelineModeYearZero;
  final int? birthYear;
  final bool alertOnPeriodicPrompts;
  final int alertTimeHour;
  final bool hideCompletedTasks;

  AppSettings copyWith({
    int? accentColor,
    bool? weekStartsOnMonday,
    bool? showQuotes,
    String? journalHotkey,
    String? todoHotkey,
    bool? hideCompletedTasks,
  }) {
    return AppSettings(
      accentColor: accentColor ?? this.accentColor,
      weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
      showQuotes: showQuotes ?? this.showQuotes,
      journalHotkey: journalHotkey ?? this.journalHotkey,
      todoHotkey: todoHotkey ?? this.todoHotkey,
      rankingColorStart: rankingColorStart,
      rankingColorEnd: rankingColorEnd,
      timelineModeYearZero: timelineModeYearZero,
      birthYear: birthYear,
      alertOnPeriodicPrompts: alertOnPeriodicPrompts,
      alertTimeHour: alertTimeHour,
      hideCompletedTasks: hideCompletedTasks ?? this.hideCompletedTasks,
    );
  }
}

class Quote {
  const Quote({required this.id, required this.text});

  final String id;
  final String text;
}

class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.documentId,
    required this.sequence,
    required this.payload,
    required this.deviceId,
    required this.timestamp,
  });

  final String id;
  final String documentId;
  final int sequence;
  final String payload;
  final String deviceId;
  final DateTime timestamp;
}

class GoogleCalendarSyncLock {
  const GoogleCalendarSyncLock({
    required this.deviceId,
    required this.lockedAt,
    required this.expiresAt,
  });

  final String deviceId;
  final DateTime lockedAt;
  final DateTime expiresAt;

  bool isValid(String requestingDeviceId, DateTime now) {
    if (now.isAfter(expiresAt)) return true;
    return deviceId == requestingDeviceId;
  }
}

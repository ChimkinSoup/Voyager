/// How often something repeats.
///
/// [EventRecurrence] used to be the whole recurrence model — a bare enum
/// stored as its own `name` in a text column. It is now the *frequency* half
/// of [RecurrenceRule]; the old storage strings still parse (see
/// [RecurrenceRule.parse]) so rows written before custom rules existed keep
/// working untouched.
enum EventRecurrence { none, daily, weekly, monthly, yearly }

/// A repeat pattern: a frequency, how many of them to skip between
/// occurrences, and — for weekly rules — which weekdays inside the week fire.
///
/// The rule describes *when a new occurrence starts*, never how long one
/// lasts. A multi-day calendar event carries its whole span forward into every
/// occurrence, so a Jan 30 → Feb 2 event repeating monthly is a four-day block
/// beginning on the 30th of each month, not four separate marks on the 30th,
/// 31st, 1st and 2nd.
class RecurrenceRule {
  const RecurrenceRule({
    this.frequency = EventRecurrence.none,
    this.interval = 1,
    this.weekdays = const {},
  });

  static const none = RecurrenceRule();

  final EventRecurrence frequency;

  /// How many [frequency] units between occurrences. `2` with
  /// [EventRecurrence.daily] is "every 2 days". Always >= 1.
  final int interval;

  /// For weekly rules: [DateTime.monday]..[DateTime.sunday] values the rule
  /// fires on. Empty means "whatever weekday the anchor falls on", which is
  /// what a plain "every week" is. Ignored for every other frequency.
  final Set<int> weekdays;

  bool get repeats => frequency != EventRecurrence.none;

  /// Whether this rule needs the custom editor to describe it — i.e. it is
  /// something other than a plain every-1-unit repeat.
  bool get isCustom =>
      repeats &&
      (interval != 1 ||
          (frequency == EventRecurrence.weekly && weekdays.isNotEmpty));

  RecurrenceRule copyWith({
    EventRecurrence? frequency,
    int? interval,
    Set<int>? weekdays,
  }) {
    return RecurrenceRule(
      frequency: frequency ?? this.frequency,
      interval: interval ?? this.interval,
      weekdays: weekdays ?? this.weekdays,
    );
  }

  /// Serializes to the `recurrence` text column.
  ///
  /// A plain every-1 rule stores as the bare frequency name, byte-identical to
  /// what the enum-only model wrote, so upgrading and then saving an untouched
  /// event produces no diff for sync to push. Anything richer appends
  /// `;i=<interval>` and `;bd=<weekday,weekday>`.
  String toStorage() {
    if (!repeats) return 'none';
    final buffer = StringBuffer(frequency.name);
    if (interval != 1) buffer.write(';i=$interval');
    if (frequency == EventRecurrence.weekly && weekdays.isNotEmpty) {
      final sorted = weekdays.toList()..sort();
      buffer.write(';bd=${sorted.join(',')}');
    }
    return buffer.toString();
  }

  /// Parses a `recurrence` column value. Unrecognized input is [none] rather
  /// than an error: a row written by a newer build must not crash an older one.
  static RecurrenceRule parse(String? value) {
    if (value == null || value.isEmpty) return none;
    final parts = value.split(';');
    final frequency = EventRecurrence.values
        .where((f) => f.name == parts.first)
        .firstOrNull;
    if (frequency == null || frequency == EventRecurrence.none) return none;

    var interval = 1;
    var weekdays = <int>{};
    for (final part in parts.skip(1)) {
      final split = part.indexOf('=');
      if (split < 0) continue;
      final key = part.substring(0, split);
      final raw = part.substring(split + 1);
      switch (key) {
        case 'i':
          final parsed = int.tryParse(raw);
          if (parsed != null && parsed >= 1) interval = parsed;
        case 'bd':
          weekdays = {
            for (final token in raw.split(','))
              if (int.tryParse(token) case final day?)
                if (day >= DateTime.monday && day <= DateTime.sunday) day,
          };
      }
    }
    return RecurrenceRule(
      frequency: frequency,
      interval: interval,
      weekdays: frequency == EventRecurrence.weekly ? weekdays : const {},
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RecurrenceRule &&
        other.frequency == frequency &&
        other.interval == interval &&
        _sameWeekdays(other.weekdays, weekdays);
  }

  @override
  int get hashCode => Object.hash(
        frequency,
        interval,
        Object.hashAllUnordered(weekdays),
      );

  @override
  String toString() => 'RecurrenceRule(${toStorage()})';
}

bool _sameWeekdays(Set<int> a, Set<int> b) =>
    a.length == b.length && a.containsAll(b);

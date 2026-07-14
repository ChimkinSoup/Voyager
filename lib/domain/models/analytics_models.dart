import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

class StatisticTracker extends SoftDeletable {
  const StatisticTracker({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.name,
    required this.type,
    required this.cadence,
    this.colorValue = 0xFF7C9EFF,
    this.showOnCalendar = false,
    this.integerCap,
    this.defaultInt = 0,
    this.defaultBool = false,
    this.enumOptions = const [],
    this.defaultEnumOption,
    this.trackingStyle,
    this.starred = false,
    this.sortOrder = 0,
  });

  final String name;
  final TrackerType type;
  final TrackerCadence cadence;
  final int colorValue;
  final bool showOnCalendar;
  final int? integerCap;
  final int defaultInt;
  final bool defaultBool;
  final List<String> enumOptions;
  final String? defaultEnumOption;

  /// Null for boolean / enum trackers (always independent/heatmap).
  /// For integer trackers, null is treated as [TrackerStyle.independent].
  final TrackerStyle? trackingStyle;

  /// Forces the tracker above all others in the grid view, regardless of
  /// [cadence]. Starred trackers form their own freely-reorderable group.
  final bool starred;

  /// Manual position within whichever group the tracker currently belongs
  /// to (the starred group if [starred], otherwise its [cadence] group).
  final int sortOrder;

  /// The resolved visualisation style, applying defaults.
  TrackerStyle? get effectiveTrackingStyle {
    if (type != TrackerType.integer) return null;
    return trackingStyle ?? TrackerStyle.independent;
  }

  StatisticTracker copyWith({
    String? name,
    bool? showOnCalendar,
    DateTime? deletedAt,
    TrackerStyle? trackingStyle,
    bool? starred,
    int? sortOrder,
  }) {
    return StatisticTracker(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      type: type,
      cadence: cadence,
      colorValue: colorValue,
      showOnCalendar: showOnCalendar ?? this.showOnCalendar,
      integerCap: integerCap,
      defaultInt: defaultInt,
      defaultBool: defaultBool,
      enumOptions: enumOptions,
      defaultEnumOption: defaultEnumOption,
      trackingStyle: trackingStyle ?? this.trackingStyle,
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class TrackerValue extends SoftDeletable {
  const TrackerValue({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.trackerId,
    required this.periodStart,
    this.intValue,
    this.boolValue,
    this.enumValue,
  });

  final String trackerId;
  final DateTime periodStart;
  final int? intValue;
  final bool? boolValue;
  final String? enumValue;
}

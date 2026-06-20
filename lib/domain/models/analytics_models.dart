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

  StatisticTracker copyWith({
    String? name,
    bool? showOnCalendar,
    DateTime? deletedAt,
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

class RankingConfig extends SoftDeletable {
  const RankingConfig({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.name,
    required this.cadence,
    required this.maxValue,
    this.colorStart = 0xFF4CAF50,
    this.colorEnd = 0xFFF44336,
  });

  final String name;
  final TrackerCadence cadence;
  final int maxValue;
  final int colorStart;
  final int colorEnd;
}

class RankingValue extends SoftDeletable {
  const RankingValue({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.configId,
    required this.periodStart,
    required this.value,
  });

  final String configId;
  final DateTime periodStart;
  final int value;
}
